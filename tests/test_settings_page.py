"""Settings > Speaka: the sections carry no footer text, and Audio output has only Play audio on and Choose output
device. The Playing on and never-play rows were removed, together with the code behind them."""
import pathlib
import plistlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
REMOVED_ROWS = ("Playing on", "Never play to current device", "Never play to", "Clear never-play list")
REMOVED_CODE = ("playingValue:", "neverValue:", "neverList", "neverPlayCurrent:", "clearNeverPlay:",
                "currentExternalOutputs", "BTPSOutputName", "BTPSOutputsDescription", "BTPSTypeLabel", "BTPSIsBuiltIn")


class SettingsPage(unittest.TestCase):
    def setUp(self):
        self.items = plistlib.loads((ROOT / "speakaprefs/Resources/Root.plist").read_bytes())["items"]
        self.controller = (ROOT / "speakaprefs/BTPSRootListController.m").read_text()

    def test_no_section_has_footer_text(self):
        groups = [item for item in self.items if item.get("cell") == "PSGroupCell"]
        self.assertGreaterEqual(len(groups), 8)
        for group in groups:
            self.assertNotIn("footerText", group, group.get("label"))

    def test_audio_output_has_only_the_two_controls(self):
        labels = [item.get("label") for item in self.items]
        start = labels.index("Audio output") + 1
        end = next(i for i in range(start, len(self.items)) if self.items[i].get("cell") == "PSGroupCell")
        self.assertEqual(labels[start:end], ["Play audio on", "Choose output device..."])
        for row in REMOVED_ROWS:
            self.assertNotIn(row, labels)

    def test_the_code_behind_the_removed_rows_is_gone(self):
        for name in REMOVED_CODE:
            self.assertNotIn(name, self.controller, name)
        self.assertIn('[self reloadSpecifierID:@"session"];', self.controller)   # only the Session row refreshes live


if __name__ == "__main__":
    unittest.main()
