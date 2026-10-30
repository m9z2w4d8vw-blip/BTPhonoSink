"""The Speaka companion app (app/): it must speak exactly the tweak's protocol, agree with the Settings page, and
package correctly for TrollStore. The Objective-C is first compiled by CI, so these checks run before that."""
import pathlib
import plistlib
import re
import struct
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "app"
SOURCES = sorted((APP / "Speaka").rglob("*.[hm]"))


def read(path):
    return pathlib.Path(path).read_text(encoding="utf-8")


def strip_comments_and_strings(src):
    src = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    return re.sub(r'@?"(?:\\.|[^"\\\n])*"', '""', src)


def png_size(path):
    data = pathlib.Path(path).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", path
    return struct.unpack(">II", data[16:24])


class SpeakaApp(unittest.TestCase):
    # ------------------------------------------------------------------ protocol
    def test_app_speaks_the_tweaks_protocol(self):
        client = read(APP / "Speaka/Model/SPTweakClient.m")
        self.assertIn('#import "BTPSShared.h"', client)
        for name in ("@BTPS_KEY_V89_REQUEST", "BTPS_NOTIFY_V89_SESSION", "@BTPS_KEY_STATUS", "@BTPS_STATUS_V89_SESSION",
                     "@BTPS_KEY_V89_HELPER", "@BTPS_KEY_V89_OUTPUT_MODE", "BTPS_NOTIFY_V89_OUTPUT", "BTPS_PREFS_DOMAIN"):
            self.assertIn(name, client)
        send = client.split("- (SPRequest *)sendAction:", 1)[1].split("\n}\n", 1)[0]
        self.assertIn('@{ @"action": action, @"nonce": nonce, @"time": @([NSDate date].timeIntervalSince1970) }', send)
        self.assertLess(send.index("SPWritePref(@BTPS_KEY_V89_REQUEST, request)"), send.index("notify_post(BTPS_NOTIFY_V89_SESSION)"))
        self.assertIn("SPWritePref(@BTPS_KEY_V89_REQUEST, nil);", send)   # withdrawn if the notification fails
        # Names come from BTPSShared.h only: no hand-typed keys or notification names anywhere in the app.
        for source in SOURCES:
            text = read(source)
            self.assertNotRegex(text, r'@"BTPhonoSink[A-Z]\w*"', source.name)
            self.assertNotIn('"com.parv.btphonosink.', text, source.name)
            self.assertNotIn('"com.apple.bluetooth"', text, source.name)

    def test_session_rules_match_the_settings_page(self):
        client = read(APP / "Speaka/Model/SPTweakClient.m")
        settings = read(ROOT / "btphonosinkprefs/BTPSRootListController.m")
        bad = r'@\[ (@"REFUSED", @"ROLLED BACK", @"UNSAFE", @"FAILED", @"SDP publish failed") \]'
        self.assertEqual(re.search(bad, client).group(1), re.search(bad, settings).group(1))
        for rule in ('[sep hasPrefix:@"LOST"]', '[trial hasPrefix:@"ARMED"]', '[trial hasPrefix:@"REFUSED"]',
                     '[sep containsString:@"register=0"]', '[sep containsString:@"SEID=7"]',
                     'status[@"diag.v89.build"]', '[session containsString:@"result=REFUSED"]'):
            self.assertIn(rule, client)
            self.assertIn(rule, settings)
        self.assertIn("> 20.0)", client)                       # helper freshness, BTPSHelperStatus(20.0)
        self.assertIn("BTPSHelperStatus(20.0)", settings)
        self.assertIn("request.relaunched ? 45.0 : 25.0", client)
        self.assertIn("self.pendingRelaunched ? 45.0 : 25.0", settings)

    def test_output_modes_match_the_settings_page(self):
        plist = plistlib.loads((ROOT / "btphonosinkprefs/Resources/Root.plist").read_bytes())
        item = next(i for i in plist["items"] if i.get("key") == "BTPhonoSinkV89OutputMode")
        client = read(APP / "Speaka/Model/SPTweakClient.m")
        modes = client.split("+ (NSArray<NSDictionary<NSString *, NSString *> *> *)outputModes", 1)[1].split("];", 1)[0]
        keys = re.findall(r'@"key": @"([^"]+)"', modes)
        titles = re.findall(r'@"title": @"([^"]+)"', modes)
        short = re.findall(r'@"shortTitle": @"([^"]+)"', modes)
        self.assertEqual(keys, item["validValues"])
        self.assertEqual(titles, item["validTitles"])
        self.assertEqual(short, item["shortTitles"])
        for symbol in re.findall(r'@"symbol": @"([^"]+)"', modes):
            self.assertRegex(symbol, r"^[a-z0-9.]+$")

    # ------------------------------------------------------------------ marquee
    def test_marquee_scrolls_right_and_wraps_without_a_jump(self):
        source = read(APP / "Speaka/UI/SPMarqueeView.m")
        # The model below mirrors these lines; if they change, update the model too.
        for line in ("CGFloat cycle = MAX(self.textWidth + SPMarqueeGap, width);",
                     "self.offset = fmod(self.offset, cycle);",
                     "self.leadLabel.frame = CGRectMake(self.offset, 0, self.textWidth, height);",
                     "self.trailLabel.frame = CGRectMake(self.offset - cycle, 0, self.textWidth, height);",
                     "self.offset += self.pointsPerSecond * (CGFloat)delta;        // positive: rightward",
                     "CFTimeInterval delta = MIN(now - self.lastTimestamp, 0.1);",
                     "return !UIAccessibilityIsReduceMotionEnabled();"):
            self.assertIn(line, source)
        gap = float(re.search(r"SPMarqueeGap = (\d+);", source).group(1))
        speed = float(re.search(r"_pointsPerSecond = (\d+);", source).group(1))
        self.assertGreater(speed, 0)
        for text_width, width in ((620.0, 280.0), (150.0, 280.0), (280.0 - gap, 280.0)):
            offset, dt = 0.0, 1 / 60
            cycle = max(text_width + gap, width)

            def visible(offset):
                offset %= cycle
                xs = [offset, offset - cycle]                       # lead, trail
                return sorted(x for x in xs if x < width and x + text_width > 0)

            before = visible(offset)
            for _ in range(int(3 * cycle / (speed * dt))):          # three full cycles
                offset += speed * dt
                after = visible(offset)
                # Every copy that stays on screen moved right by exactly one step: no jump at the wrap.
                for x in after:
                    if x > -text_width + speed * dt:
                        self.assertTrue(any(abs(x - (b + speed * dt)) < 1e-6 for b in before),
                                        f"jump at offset {offset % cycle:.2f}: {before} -> {after}")
                self.assertTrue(after, "the banner went blank")
                before = after

    # ------------------------------------------------------------------ bundle
    def test_bundle_contents(self):
        info = plistlib.loads((APP / "Resources/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleExecutable"], "Speaka")
        self.assertEqual(info["CFBundleIdentifier"], "com.parv.speaka")
        self.assertEqual(info["MinimumOSVersion"], "15.0")
        self.assertIn("UILaunchScreen", info)
        scene = info["UIApplicationSceneManifest"]["UISceneConfigurations"]["UIWindowSceneSessionRoleApplication"][0]
        self.assertIn("@implementation %s" % scene["UISceneDelegateClassName"], read(APP / "Speaka/SPSceneDelegate.m"))
        expected = {"AppIcon60x60@2x.png": 120, "AppIcon60x60@3x.png": 180,
                    "AppIcon76x76@2x~ipad.png": 152, "AppIcon83.5x83.5@2x~ipad.png": 167}
        for name, pixels in expected.items():
            self.assertEqual(png_size(APP / "Resources" / name), (pixels, pixels), name)
        for icons in (info["CFBundleIcons"], info["CFBundleIcons~ipad"]):
            for base in icons["CFBundlePrimaryIcon"]["CFBundleIconFiles"]:
                self.assertTrue(any(n.startswith(base + "@") for n in expected), base)
        self.assertEqual(png_size(APP / "Artwork/AppIcon-1024.png"), (1024, 1024))

    def test_entitlements_are_only_what_the_app_needs(self):
        entitlements = plistlib.loads((APP / "Speaka.entitlements").read_bytes())
        self.assertEqual(entitlements, {"platform-application": True, "com.apple.private.security.no-sandbox": True})

    def test_dopamine_ui_is_credited_under_its_license(self):
        license_text = read(APP / "Resources/LICENSE-Dopamine.txt")
        self.assertTrue(license_text.startswith("MIT License"))
        self.assertIn("Copyright (c) 2023-2024 Lars Fröder (opa334)", license_text)
        self.assertIn("The above copyright notice and this permission notice shall be included", license_text)
        adapted = [s for s in SOURCES if "Dopamine's DO" in read(s)]
        self.assertGreaterEqual(len(adapted), 20)
        for source in adapted:
            self.assertIn("Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).",
                          read(source), source.name)
        credits = read(APP / "Speaka/UI/SPCreditsViewController.m")
        self.assertIn('pathForResource:@"LICENSE-Dopamine" ofType:@"txt"', credits)
        # Speaka has its own name, icon and background: none of Dopamine's images are used.
        for source in SOURCES:
            self.assertNotIn("imageNamed:", read(source), source.name)

    # ------------------------------------------------------------------ build
    def test_makefile_builds_every_source_and_packages_a_tipa(self):
        make = read(APP / "Makefile")
        self.assertIn("APPLICATION_NAME = Speaka", make)
        self.assertIn("include $(THEOS_MAKE_PATH)/application.mk", make)
        self.assertIn("Speaka_CODESIGN_FLAGS = -SSpeaka.entitlements", make)
        self.assertIn("-I..", make)                                   # BTPSShared.h at the repository root
        dirs = re.findall(r"\$\(wildcard (\S+)/\*\.m\)", make)
        for source in (s for s in SOURCES if s.suffix == ".m"):
            self.assertIn(source.parent.relative_to(APP).as_posix(), dirs, source.name)
        for framework in ("UIKit", "AVFoundation", "QuartzCore"):
            self.assertIn(framework, re.search(r"Speaka_FRAMEWORKS = (.+)", make).group(1))
        tipa = make.split("tipa: stage", 1)[1]
        self.assertIn("$(THEOS_STAGING_DIR)/Applications/Speaka.app", make)
        self.assertIn('zip -qry "$(CURDIR)/packages/Speaka.tipa" Payload', tipa)

    def test_workflow_builds_the_app_without_risking_the_tweak(self):
        workflow = read(ROOT / ".github/workflows/build.yml")
        app_job = workflow.split("\n  app:\n", 1)[1].split("\n  release:\n", 1)[0]
        self.assertIn("make -C app clean tipa FINALPACKAGE=1", app_job)
        self.assertIn("name: Speaka-tipa", app_job)
        self.assertIn("com.apple.private.security.no-sandbox", app_job)
        release = workflow.split("\n  release:\n", 1)[1]
        self.assertIn("needs: build\n", release)                       # the release never waits for the app

    def test_objective_c_is_structurally_sound(self):
        include_dirs = [APP / d for d in ("Speaka", "Speaka/Model", "Speaka/UI", "Speaka/UI/Transition")] + [ROOT]
        for source in SOURCES:
            raw = read(source)
            code = strip_comments_and_strings(raw)
            depth = {"(": 0, "[": 0, "{": 0}
            closing = {")": "(", "]": "[", "}": "{"}
            for ch in code:
                if ch in depth:
                    depth[ch] += 1
                elif ch in closing:
                    depth[closing[ch]] -= 1
                    self.assertGreaterEqual(depth[closing[ch]], 0, f"{source.name}: unbalanced {ch}")
            self.assertEqual(depth, {"(": 0, "[": 0, "{": 0}, source.name)
            opens = len(re.findall(r"^\s*@(?:interface|implementation|protocol)\b(?!\s+\w+\s*;)", code, re.M))
            self.assertEqual(opens, len(re.findall(r"^\s*@end\b", code, re.M)), source.name)
            for name in re.findall(r'^\s*#\s*(?:import|include)\s+"([^"]+)"', raw, re.M):
                self.assertTrue(any((d / name).exists() for d in [source.parent] + include_dirs),
                                f"{source.name}: #import \"{name}\" does not resolve")
            if source.suffix == ".m" and source.with_suffix(".h").exists():
                self.assertIn(f'#import "{source.with_suffix(".h").name}"', raw, source.name)


if __name__ == "__main__":
    unittest.main()
