# Speaka app

The app for the Speaka tweak. It offers:

- **Start** and **Stop** for the speaker;
- an **Audio output** menu that unfolds into the three outputs;
- a connection banner that scrolls to the right and shows who is connected.

It is a TrollStore app, published as `Speaka.tipa` and `Speaka.ipa` (the same file), and built separately from
the tweak's `.deb`.

The user interface is adapted from [Dopamine](https://github.com/opa334/Dopamine) by Lars Fröder (opa334) and its
contributors, under the MIT License. The license ships in the app (`Resources/LICENSE-Dopamine.txt`, shown under
**Credits**). Every adapted file names its Dopamine original in its header. The name, icon and background are Speaka's
own; no Dopamine image is used.

## Build and install

```sh
make -C app tipa FINALPACKAGE=1      # -> app/packages/Speaka.tipa and Speaka.ipa (the same file)
```

CI builds it in its own job, **Build the Speaka app**, and uploads both files as the `Speaka-app` artifact. The
release attaches them next to the tweak's `.deb`. If the app fails to build, the release goes out without it rather than not at
all.

To install, open `Speaka.tipa` or `Speaka.ipa` with TrollStore. The Speaka tweak package (`.deb`) must be installed as well:
the app only controls the tweak. Sideloading it with AltStore or Sideloadly would strip its two entitlements, and
without them it cannot reach the tweak.

## How it talks to the tweak

Exactly like Settings > Speaka, through the `com.apple.bluetooth` preferences and the Darwin notifications in
[`BTPSShared.h`](../BTPSShared.h). This needs two entitlements, `platform-application` and
`com.apple.private.security.no-sandbox`, and nothing else.

| Action | What the app does |
| --- | --- |
| Start / Stop | Writes `{action, nonce, time}` to `SpeakaV89SessionRequest`, posts `com.parv.speaka.v89.session`, then follows `diag.v89.session` until the tweak answers that nonce |
| Status | Reads `SpeakaStatus` and `SpeakaV89HelperStatus` every 0.5 s, with the same rules as the Settings page |
| Audio output | Writes `SpeakaV89OutputMode`, then posts `com.parv.speaka.v89.output`; the helper switches mid-song |
| PC name | Best effort, from the private BluetoothManager framework; otherwise the banner says "Your PC" |

`tests/test_speaka_app.py` checks that the app keeps agreeing with the Settings page on these points:

- key names;
- session rules;
- timeouts;
- output titles.

## Files

| File | From Dopamine | Role |
| --- | --- | --- |
| `Speaka/main.m`, `SPAppDelegate`, `SPSceneDelegate` | `main.m`, `DOAppDelegate`, `DOSceneDelegate` | App launch |
| `Speaka/Model/SPTweakClient` | | The tweak's protocol and the Settings page's rules |
| `Speaka/Model/SPConnectedDevice` | | Best-effort name of the connected PC |
| `Speaka/UI/SPNavigationController` | `DONavigationController` | Background, card frames, transitions |
| `Speaka/UI/SPMainViewController` | `DOMainViewController` (layout) | The main screen |
| `Speaka/UI/SPGlobalAppearance` | `DOGlobalAppearance` | Button style, fonts, sizes |
| `Speaka/UI/SPTheme` | `DOThemeManager` (default colours) | Panel colours; Speaka's own background |
| `Speaka/UI/SPHeaderView` | `DOHeaderView` | Title and subtitles |
| `Speaka/UI/SPActionMenuView`, `SPActionMenuButton` | `DOActionMenuView`, `DOActionMenuButton` | The menu panel and its rows |
| `Speaka/UI/SPBigButton` | `DOJailbreakButton` | Start and Stop, with the working state |
| `Speaka/UI/SPDoubleHelixIndicator` | `DODoubleHelixIndicator` | The working-state animation |
| `Speaka/UI/SPOutputDropdown` | (built from `DOActionMenuButton`) | The Audio output menu |
| `Speaka/UI/SPMarqueeView` | | The rightward-scrolling connection banner |
| `Speaka/UI/SPCreditsViewController` | | Credits card with the MIT License |
| `Speaka/UI/Transition/*` | `DOModalBackAction`, `DOModalTransitionScale`, `DOModalTransitionPush` | Card transitions |
| `Resources/` | | `Info.plist`, icons, `LICENSE-Dopamine.txt` |
| `Artwork/` | | The 1024 px icon and `make_icon.py`, which draws it |

To redraw the icon, run `python3 app/Artwork/make_icon.py app/Artwork/AppIcon-1024.png` (it needs Pillow and
NumPy), then export the sizes listed in `Resources/Info.plist`.
