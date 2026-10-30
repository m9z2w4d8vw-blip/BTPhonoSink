# Speaka

[![build](https://github.com/m9z2w4d8vw-blip/Speaka/actions/workflows/build.yml/badge.svg)](https://github.com/m9z2w4d8vw-blip/Speaka/actions/workflows/build.yml)

**Use a jailbroken iPhone as a Bluetooth speaker for your PC.**

iOS only implements the sending side of Bluetooth audio (A2DP *Source*). It can stream to headphones, but nothing can stream to it.
Speaka adds the receiving side (A2DP *Sink*), the role headphones and speakers implement, to the iPhone's Bluetooth daemon. Your PC
then lists the iPhone as a speaker, and whatever it plays comes out of the iPhone's loudspeaker, a pair of wired earbuds, or another
iOS audio output.

**Status (v8.9.4):** working end to end with a Windows laptop:

- connecting and streaming;
- pausing, resuming and changing songs;
- switching outputs during playback;
- wired earbuds without replugging.

It is an experimental tweak that modifies a system daemon through private internals, and it supports exactly one `bluetoothd` build
(see [Requirements](#requirements)).

**About the name.** Everything is called Speaka: the package (`com.parv.speaka`), the tweak inside Bluetooth
(`Speaka.dylib`), the Settings page, the app and the release files. Version 9.0 completed the rename. If you have a
build from before it, remove that package once before installing this one; [TESTING-v9.0](docs/history/TESTING-v9.0.md)
has the steps.

## Contents

- [Requirements](#requirements)
- [Install and uninstall](#install-and-uninstall)
- [Using it](#using-it)
- [The Speaka app](#the-speaka-app)
- [Troubleshooting](#troubleshooting)
- [Logs and diagnostics](#logs-and-diagnostics)
- [How it works](#how-it-works)
- [Repository layout](#repository-layout)
- [Building and testing](#building-and-testing)
- [Safety and recovery](#safety-and-recovery)
- [Known limitations](#known-limitations)
- [Version history](#version-history)
- [Credits](#credits)

## Requirements

| What | Requirement |
| --- | --- |
| iPhone | iOS 17.0, arm64e. Developed on an iPhone 13. |
| Jailbreak | Rootless (Dopamine) with ElleKit and PreferenceLoader. The package depends on `mobilesubstrate`, `preferenceloader` and `firmware (>= 14.0)`. |
| `bluetoothd` | Exactly the analysed build: 10,196,720 bytes, arm64e, SHA-256 `e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6`, LC_UUID `5491BA47-B5AE-3D44-9536-B30161DF1E90`. |
| Sending device | Any Bluetooth A2DP audio source using SBC. Developed with a Windows laptop. |

The tweak hooks functions by address, and addresses are only valid for one build of the daemon. Before hooking anything, it checks
two things:

- the daemon's LC_UUID;
- the first four instructions of every function it touches.

On any mismatch it logs the reason and hooks nothing, so an unsupported build means "no speaker", not a crashing Bluetooth daemon.
Settings > Speaka > Status and the first block of the debug log (`hooks installed: 5 / 5`) show whether it loaded.

## Install and uninstall

Download the `.deb` from the [**nightly** pre-release](https://github.com/m9z2w4d8vw-blip/Speaka/releases). It is rebuilt from
`main` on every push; check your download against its `SHA256SUMS`. Each workflow run's `Speaka-deb` artifact works too.
Open the `.deb` with Sileo or Zebra, or install it over SSH:

```sh
sudo dpkg -i Speaka_*.deb
```

The install script does three things:

- registers the audio helper with launchd;
- creates `/tmp/FTABHarvest`;
- restarts `bluetoothd` once, so the new build is the one running.

Your Bluetooth devices reconnect within a few seconds, and Settings gains a **Speaka** page. Installing alone does not turn the
speaker on; tap **Start** for that.

Upgrading from a build older than v9.0? Remove the old package first; see
[TESTING-v9.0](docs/history/TESTING-v9.0.md).

To remove it, uninstall the package, which also unloads the helper, and then restart Bluetooth to unload the tweak from the running
daemon:

```sh
sudo dpkg -r com.parv.speaka
sudo killall -9 bluetoothd
```

## Using it

### Start, connect, stop

Open **Settings > Speaka** (or the Speaka app) and tap **Start**. The tweak arms a one-time speaker session and restarts Bluetooth itself, with no
command line needed. After a few seconds **Session** reads `On - connect from your PC`.

On the PC, pair with the iPhone (Windows: Settings > Bluetooth & devices > Add device > Bluetooth) and choose it as the sound output.
While audio arrives, Session reads `On - receiving audio`.

The speaker endpoint lives as long as that run of `bluetoothd`. Tap **Start** again in these cases:

- after a reboot, which on Dopamine also means re-jailbreaking;
- after a userspace reboot;
- after turning Bluetooth or Airplane Mode off and on. Session then reads `Off - Bluetooth was turned off and on; tap Start`, because
  iOS rebuilds its endpoints without the speaker.

**Stop and restore normal Bluetooth** restarts Bluetooth without the speaker endpoint.

### Choosing where the audio plays

**Play audio on** takes effect immediately, even mid-song:

| Setting | Plays on | Details |
| --- | --- | --- |
| iPhone speaker (default) | The built-in loudspeaker, always | Ignores plugged-in headphones. The most tested mode. |
| Wired headphones or earbuds | A wired or USB headset plugged into the iPhone | Never uses Bluetooth, so the sound cannot go back to the PC. Wins even if the PC connected later. Waits while nothing is plugged in and starts as soon as something is. |
| Any device (follow iOS) | Wherever iOS is playing: Control Center or **Choose output device...** | The mode for Bluetooth earbuds. See below. |

**Playing on** shows the helper's current output with its type, for example `Headphones (wired)` or `LAPTOP-XXXX (Bluetooth)`. It
appends `- volume 0%` when that output's volume is at zero. While the helper waits it shows the reason, for example
`Waiting: no wired headphones plugged in`.

**Bluetooth earbuds** need *Any device*, plus a one-time step. The PC that sends the audio is itself a Bluetooth audio device to iOS,
and because it connects last, iOS sends media to it. Fix it once:

1. While music plays, check **Playing on**.
2. If it shows your PC, tap **Never play to current device**. It is remembered by device ID and name.
3. Pick the earbuds with **Choose output device...**.

**Clear never-play list** undoes this.

### The Settings page

| Section | Rows | What it is for |
| --- | --- | --- |
| Status | Loaded in daemon, Last event, Log channels | Whether the tweak is running inside `bluetoothd`, and whether its log channels work. |
| Bluetooth speaker | Start, Stop and restore normal Bluetooth, Session | Turning the speaker on and off, and its current state. |
| Audio output | Play audio on, Choose output device..., Playing on, Never play to current device, Never play to, Clear never-play list | Where the audio goes. |
| Debug log | View debug log, Copy log to clipboard, Clear log | Everything needed to diagnose a problem. See [Logs and diagnostics](#logs-and-diagnostics). |
| Lower sections | Research switches from v7 to v8.8 | **Start** sets the two one-shot switches (*Arm seven slots for ONE restart*, *Arm real Sink SDP + signaling ONCE*) and clears *Legacy sink experiment flag*. Each launch consumes them. Leave the tracing switches off. |

The debug log page also keeps the self-tests from the research stages: a 440 Hz output test, a PCM transfer to the helper, and
compressed SBC fixtures sent from `bluetoothd`. None of them involve the PC.

## The Speaka app

Speaka also has its own app, so you don't have to dig through Settings. It is a TrollStore app with a user interface
adapted from Dopamine. It does the same as the Speaka page in Settings:

- **Start** and **Stop** for the speaker, with Bluetooth's restart shown in the button;
- **Audio output**, a menu that unfolds into iPhone speaker, Wired headphones or earbuds, and Any device;
- a connection banner that scrolls to the right. It shows when your PC is connected and where the audio is playing,
  for example *LAPTOP-XXXX connected · playing on iPhone speaker*.

The app and the Settings page always agree, because they read and write the same settings.

To install it, download `Speaka.tipa` or `Speaka.ipa` from the same
[**nightly** pre-release](https://github.com/m9z2w4d8vw-blip/Speaka/releases) as the `.deb`. They are the same file
under two names, and each workflow run's `Speaka-app` artifact has both too. Open it with TrollStore, which supports
iOS 17.0. Sideloading it with AltStore or Sideloadly installs it, but without the permissions it needs to control the
tweak. The Speaka package (the `.deb`) must be installed too: the app only controls the tweak. Details and the
file map are in [app/README.md](app/README.md).

## Troubleshooting

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| Start ends with "Still waiting" | `bluetoothd` still runs an older tweak build that has no Start handler | Check `diag.v89.build` in **View debug log**. Reinstall the package (its install script restarts `bluetoothd`), or run `sudo killall -9 bluetoothd`, then Start again. |
| Session: `Off - Bluetooth was turned off and on; tap Start` | Toggling Bluetooth rebuilt Apple's endpoints without the speaker | Tap **Start**. |
| The PC connects and immediately disconnects, or finds no speaker | No speaker endpoint registered: Bluetooth was toggled, or Start was not tapped since the last restart | Tap **Start**, then reconnect from the PC. |
| The PC says it is playing, the iPhone is silent, and **Playing on** shows your PC `(Bluetooth)` | *Any device* is sending the sound back to the PC | Choose *iPhone speaker* or *Wired headphones*, or tap **Never play to current device**. |
| **Playing on** ends in `- volume 0%` | That output's volume is at zero | Raise the iPhone volume while audio plays. |
| Wired mode is silent: `Waiting: no wired headphones plugged in` | Nothing is plugged in | Plug the headset in; playback starts by itself. |
| Audio stopped after a call, Siri, or another app played sound | iOS interrupted the helper | Pause and play on the PC, or change any audio setting. |
| Bluetooth misbehaves in general | | Tap **Stop and restore normal Bluetooth**. Without Settings: `sudo killall -9 bluetoothd`. To remove everything, uninstall (see [above](#install-and-uninstall)). |

When reporting a problem, use **Save Log to iCloud Drive** on the debug log page right after it happens.

## Logs and diagnostics

**View debug log** collects everything in one place:

- the daemon's status block;
- the daemon's log;
- an **AUDIO HELPER** section: the output mode, the never-play list, the helper's last status (state, device, type, volume) and the
  tail of the helper's own log.

**Copy log to clipboard** and **Save Log to iCloud Drive** export the same text.

| File | Written by | Notes |
| --- | --- | --- |
| `/tmp/FTABHarvest/Speaka.log` | The tweak inside `bluetoothd` | Cleared when it passes 512 KB. The last 480 lines are also mirrored into preferences, which is what Settings shows. Packet traffic is summarized every 2 s, so this covers several minutes. |
| `/tmp/FTABHarvest/BTPSAudioHelper-v88.log` | `BTPSAudioHelper` (launchd stdout and stderr) | Timestamped like the daemon log. launchd appends to it indefinitely; Settings reads only its tail. |

To copy both to a Windows PC:

```powershell
scp mobile@<iphone-ip>:/tmp/FTABHarvest/Speaka.log "$env:USERPROFILE\Downloads\"
scp mobile@<iphone-ip>:/tmp/FTABHarvest/BTPSAudioHelper-v88.log "$env:USERPROFILE\Downloads\"
```

Lines worth knowing:

| Line | Meaning |
| --- | --- |
| `diag.v89.build: v9.0.0-one-tap-output-select` | The tweak build running inside `bluetoothd` |
| `diag.v89.session: start nonce=... result=ARMED` | Start restarted Bluetooth and armed the session |
| `diag.v82.sep: LOCAL register=0 SEID=7 role=SNK ...` | The speaker endpoint is registered |
| `V88_CONFIG handle=1 local_seid=7 remote_seid=...` | The PC configured a stream |
| `V88_STREAM active=1 generation=N` | The stream started; `active=0` means paused or closed |
| `V893_RX 2000ms forwarded=... ok=... decoded=... bad=...` | Two seconds of reception; errors are also logged one per line |
| `V881_PCM ... peak=... \| RENDER ... silence_frames=...` | Audio level, and underruns (`silence_frames`) |
| `V882_HEALTH ready=0 ... why=0x20` | Helper health. Reason bits: `0x1` stream inactive, `0x2` no queue, `0x4` queue stopped, `0x8` stopping, `0x10` enqueue error, `0x20` output not right for the selected mode |
| `V882_IDLE_GUARD action=keep` | The guard kept the stream alive instead of iOS's idle suspend |
| `V82 TX_SIGNAL ... msg=0 sig=9` / `V82 RX_SIGNAL ... msg=0 sig=9` | The phone / the PC sent AVDTP SUSPEND (`sig=7` START, `sig=8` CLOSE) |
| Helper `V889_AUDIO_ROUTE stage=... mode=... type=... name=... volume=...` | Exactly where the audio went |
| Helper `V882_AUDIO_STOP reason=...` | Why the helper stopped playing |
| Helper `V882_INTERRUPTION type=began reason=...` | iOS interrupted playback (a call, Siri, another app) |

Offline helpers in `tools/`:

| Script | Purpose |
| --- | --- |
| `fetch_google_sbc.sh` | Fetches Google libsbc at the pinned commit into `btpsaudiohelper/vendor_sbc/` (CI runs it) |
| `decode_rtp_sbc.py` | Decodes captured A2DP RTP/SBC packets offline |
| `sdp_record.py` | Builds and decodes the A2DP Audio Sink SDP attribute list (used by `tests/test_sdp_record.py`) |
| `inspect_bluetoothd.py` | Read-only evidence collector for a `bluetoothd` binary |
| `triage_log.py` | Interprets exported Settings logs from the early (v5/v6) builds |
| `windows_bluetooth_snapshot.ps1` | Read-only snapshot of the PC's Bluetooth state; changes nothing |

## How it works

```text
 PC (A2DP source)
   |  Bluetooth: AVDTP signaling + SBC media
   v
 bluetoothd + Speaka tweak                        Settings > Speaka
   |  hooks verified against one exact build          |  preferences (com.apple.bluetooth)
   |  7th AVDTP endpoint: Sink SEID 7 + SDP 0x110B     |  + Darwin notifications
   |  media callback -> lock-free shared ring          |
   v  (locked memory, file in /tmp/FTABHarvest)        |
 BTPSAudioHelper (launchd, user mobile)  <-----------'   output mode, never-play list, status
   |  Google libsbc -> 16-bit stereo PCM -> AudioQueue
   v
 iPhone speaker / wired earbuds / any iOS output
```

### Inside bluetoothd

`Tweak.xm` is loaded into `bluetoothd` (filter: `Speaka.plist`). Its five offset hooks come from `BTPSBuild.h`, which is
generated from the analysed binary. Every target is verified by LC_UUID and instruction signature before hooking. Two targets do the
work, and the other three are pass-through observers for diagnostics:

| Function | Offset | Role |
| --- | --- | --- |
| `AVDTP_RegisterMultipoint` | `0x00cecf0` | Watches Apple's six native Source registrations, then registers the one Sink endpoint |
| `SetConfigInd_handler` | `0x037ae68` | Learns the Sink stream handle and the local and remote endpoint IDs when the PC configures a stream |
| `advertise_A2DP_source` | `0x044df14` | Observer |
| `SetConfig_accept_SBC` | `0x03b03b4` | Observer (logs the accepted SBC configuration) |
| `publish_audio_device` | `0x0376e4c` | Observer |

The rest of the design, in order:

1. **A seventh endpoint slot (v8.1).** AVDTP is configured for six endpoints, all used by Apple's Sources. A one-shot shadow of
   AVDTP's configuration (getter index 3) makes room for a seventh.
2. **The speaker endpoint (v8.2).** After the six Sources register, the tweak registers one Sink endpoint (TSEP 1, SEID 7, SBC). It
   then adds a local SDP Audio Sink record (UUID `0x110B`), so the PC discovers a speaker. AVDTP signaling is observed and logged,
   and a small state machine (`BTPSV88Control.c`) tracks the stream. Apple's handling is never altered.
3. **Media (v8.8).** Apple's stream callback table has 27 pointer-authenticated entries. The tweak copies it whole and replaces only
   slot `+0xb0`, a no-op stub at `+0x385dfc`, so incoming SBC packets reach the tweak's callback. That callback copies each payload
   into a ring of 32 slots of 2048 bytes in locked shared memory, with no locks, allocation, logging or system calls on Bluetooth's
   receive thread (`BTPSV88Daemon.c`, `BTPSV88Shared.c`).
4. **A worker thread.** Every 20 ms it connects to the helper, drains the log and event queues, and maintains the helper's health
   lease.
5. **The idle guard (v8.8.2).** iOS's idle check at `+0x376034` would suspend a stream that iOS itself is not playing, and from
   iOS's point of view nothing plays: the audio goes to the helper. While the helper is healthy (fresh media, heartbeat and
   rendering), the guard keeps the stream; otherwise Apple's decision stands (`BTPSV882Health.h`).
6. **Start and Stop (v8.9.2).** Settings writes `{action, nonce, time}` and posts `com.parv.speaka.v89.session`. The tweak
   validates the request, sets the one-shot switches, reads them back, and restarts `bluetoothd` by killing itself (`BTPSV89Session.c`).
   It runs as `mobile`, so it cannot use `launchctl kickstart`. launchd relaunches it, and the new daemon reports `ARMED`.
7. **Bluetooth toggles (v8.9.2).** Turning Bluetooth off and on re-runs Apple's endpoint registration inside the same daemon, without
   the Sink. The tweak notices the second pass, stops forwarding, and reports the loss.

### The audio helper

`BTPSAudioHelper` (`btpsaudiohelper/`) runs outside `bluetoothd`. launchd job `com.parv.speaka.audio` listens on
`127.0.0.1:37594` as user `mobile` and starts the helper on the daemon's first connection after a stream START.

The helper maps the shared ring and decodes SBC with Google libsbc, pinned and fetched at build time (`BTPSV88Decode.c`). It plays
the PCM through AudioQueue (`BTPSV88Stream.m`). Each output mode maps to an AVAudioSession setup; nothing records and no input is
ever opened:

| Mode | AVAudioSession |
| --- | --- |
| iPhone speaker | PlayAndRecord with DefaultToSpeaker, plus a speaker override |
| Wired headphones or earbuds | PlayAndRecord with no Bluetooth option, so only wired or USB outputs qualify |
| Any device | Playback, which follows iOS's choice |

The route policy is plain C in `BTPSV89Output.h` and is tested directly. The helper also:

- services its main run loop so route changes and interruptions are delivered;
- clears an interruption when the PC starts a new stream or a setting changes, so it can never stay muted;
- reports health to the daemon every ~0.2 s;
- publishes its status for Settings.

### Settings

`speakaprefs/` is a PreferenceLoader bundle (`Resources/Root.plist` plus `BTPSRootListController.m`). It shares the
`com.apple.bluetooth` preferences domain with `bluetoothd` and signals it with Darwin notifications.
`BTPSLogReader.m` assembles the debug log export.

| Name | Kind | Purpose |
| --- | --- | --- |
| `SpeakaV89SessionRequest` / `...SessionPending` | Preference | Start/Stop request; consumed by the tweak, carried across its restart |
| `com.parv.speaka.v89.session` | Darwin notification | "A session request is waiting" |
| `SpeakaV81SevenOnce`, `SpeakaV82DecisiveOnce` | Preference | The one-shot switches that Start sets and the next launch consumes |
| `SpeakaV89OutputMode` | Preference | `speaker`, `headphones` (wired) or `any` |
| `SpeakaV89NeverOutputs` | Preference | Never-play list, `[{uid, name}]` |
| `com.parv.speaka.v89.output` | Darwin notification | Output settings changed |
| `SpeakaV89HelperStatus` | Preference | The helper's state, reason, outputs and volume |
| `127.0.0.1:37594` | TCP (launchd socket) | Daemon-to-helper connection |
| `/tmp/FTABHarvest/` | Directory | Shared ring file and both logs |

## Repository layout

```text
.
|-- Tweak.xm, BTPS*.c/.h      the tweak loaded into bluetoothd (compiled by ./Makefile)
|   |-- BTPSBuild.h               offsets and signatures of the one supported bluetoothd build
|   |-- BTPSV88*.c/.h, BTPSV882Health.h   shared ring, stream control, worker, health lease (v8.8)
|   |-- BTPSV89Session.c/.h       Start/Stop handling (v8.9)
|   |-- BTPSV7x/V8x*.c/.h         earlier research stages still compiled in (capacity, geometry, SDP, fixtures)
|   `-- BTPSShared.h              preference keys, notification names and log paths shared by all three parts
|-- SBCSink.mm, sbc_decode.c    the original in-daemon decoder and player (inactive; see Known limitations)
|-- Makefile, control, Speaka.plist   Theos build, package metadata, injection filter (bluetoothd only)
|-- btpsaudiohelper/            BTPSAudioHelper: decode and playback (Theos tool)
|   `-- vendor_sbc/               Google libsbc, fetched at build time (only its README is committed)
|-- speakaprefs/           the Settings page (Theos bundle) and its Resources/
|-- app/                        the Speaka app (Theos application, packaged as Speaka.tipa/.ipa); see app/README.md
|-- layout/                     files installed as-is: DEBIAN/postinst and prerm, the launchd job, PreferenceLoader entry
|-- tests/                      the test suite (Python unittest; many tests compile the real C sources) and fixtures/
|-- tools/                      offline scripts (see Logs and diagnostics)
|-- docs/history/               release notes and test procedures for every version
|-- docs/research/              reverse-engineering findings
`-- .github/workflows/build.yml CI: test, build, package, publish
```

Shared sources live once, at the repository root. Where a subproject needs one (`BTPSIPCProtocol.c`, `BTPSMedia.c`, `BTPSV75RTP.c`,
`BTPSV88Shared.c`, `sbc_decode.c`), its folder holds a one-line `#include "../file.c"`. The copies cannot drift apart.
`tests/test_repo_layout.py` keeps this layout true and fails CI with an explanation in these cases:

- a file is uploaded to the wrong folder;
- a `(1)` duplicate appears;
- a root source becomes unused;
- a README link breaks.

## Building and testing

### GitHub Actions

Every push runs `.github/workflows/build.yml` on `macos-15`, with Xcode's iPhoneOS SDK and the latest Theos. The workflow:

1. fetches the pinned libsbc;
2. runs the whole test suite;
3. builds with `make clean package FINALPACKAGE=1`;
4. checks the package's contents;
5. uploads it as the `Speaka-deb` artifact (published as `Speaka_<version>_iphoneos-arm64.deb`), kept for 14 days.

A separate job, **Build the Speaka app**, builds and checks `Speaka.tipa` and `Speaka.ipa` (the same package under
two names) and uploads them as the `Speaka-app` artifact. The release then carries both next to the `.deb`, with all
three in `SHA256SUMS`. If the app fails to
build, the release still goes out with the `.deb`, and its notes say that the app is missing.

Pushes to `main` then republish the rolling **nightly** pre-release. A tag such as `v0.2.0` publishes release `0.2.0`. Package
versions are `control`'s `Version` plus the run number (`0.1.0.N`), so every build is newer than the last.

### Building locally

You need macOS with Xcode and [Theos](https://theos.dev):

```sh
export THEOS=~/theos
bash tools/fetch_google_sbc.sh        # Google libsbc at the pinned commit -> btpsaudiohelper/vendor_sbc/
make clean package FINALPACKAGE=1     # -> packages/com.parv.speaka_*.deb (rootless, arm64 + arm64e;
                                      #    CI publishes it as Speaka_<version>_iphoneos-arm64.deb)
make -C app tipa FINALPACKAGE=1       # -> app/packages/Speaka.tipa and Speaka.ipa (the companion app)
```

The build is rootless only: the install script and the launchd job use `/var/jb` paths. `BTPS_WITH_PREFS=0` skips the Settings
bundle. `BTPS_WITH_IPC_HELPER=0` skips the audio helper, which leaves you without audio.

### Tests

```sh
python3 -m unittest discover -s tests -v
BTPS_SANITIZE=1 python3 -m unittest discover -s tests     # AddressSanitizer + UBSan where tests compile C
```

Tests either check the sources statically or compile the real C files with the host compiler: the shared ring, the daemon's log
summarizer, the route policy and the SBC decoders. The SDP record is checked against a Python model in `tools/sdp_record.py`. The decoder and runtime tests need libsbc, so run
`tools/fetch_google_sbc.sh` first; without it, `test_v88_runtime` fails by design. CI runs the same suite before every build.

### Porting to another iOS build

Every offset and signature in `BTPSBuild.h` and `Tweak.xm` belongs to one `bluetoothd` binary, so another build means re-deriving all
of them. `docs/research/` and [PROVENANCE-v8.2](docs/history/PROVENANCE-v8.2.md) record how each was found, and
`tools/inspect_bluetoothd.py` collects the evidence. Until then, the identity check keeps a mismatched build safe: no hooks.

## Safety and recovery

The tweak changes how a system daemon behaves, through undocumented internals that Apple does not support. Three design choices
limit the damage:

- It refuses to hook a build it was not made for.
- It keeps Apple's own signaling and Source endpoints untouched.
- Each speaker session is one-shot: the switches are consumed at launch, so the next Bluetooth restart always comes back as normal
  Bluetooth.

If anything goes wrong, recover with these steps, from least to most drastic:

1. **Stop and restore normal Bluetooth**.
2. `sudo killall -9 bluetoothd`.
3. Uninstall the package.

## Known limitations

- **One `bluetoothd` build** (iOS 17.0; see [Requirements](#requirements)).
- **One session per `bluetoothd` run.** Tap Start again after a restart or a Bluetooth toggle.
- **SBC only, one stream at a time.** The Sink endpoint accepts SBC; there is one endpoint, so one sending device at a time.
- **Playback is controlled from the PC.** The tweak adds no media controls on the iPhone.
- **Bluetooth earbuds are less tested.** They need *Any device* plus the one-time never-play step. Playing to them while receiving
  from the PC (Source and Sink at once) has not been tested on a device.
- **Inactive legacy code is still compiled into the tweak.** This includes the first design's in-daemon decoder and player
  (`SBCSink.mm`; nothing calls it, and a test makes sure the live path never does) and the v7 diagnostic paths. Removing them
  changes the built tweak, so it belongs in its own tested release.

## Version history

Each version's notes describe what changed, why, and how it was tested on the device. There are no v8.4 or v8.5 notes.

| Version | Milestone | Notes |
| --- | --- | --- |
| v5 | First on-device checklist for the hook build | [TESTING-v5](docs/history/TESTING-v5.md) |
| v6 | Device testing procedure | [TESTING-v6](docs/history/TESTING-v6.md) |
| v7 | Optional SDP registration observation | [TESTING-v7](docs/history/TESTING-v7.md) |
| v7.1 | iCloud log export, SDP research, receive-side media foundation | [TESTING-v7.1](docs/history/TESTING-v7.1.md) |
| v7.2 | Verified test sequence | [TESTING-v7.2](docs/history/TESTING-v7.2.md) |
| v7.3 | Cross-process PCM playback in a separate helper | [TESTING-v7.3](docs/history/TESTING-v7.3.md) |
| v7.4 | `bluetoothd` to independent audio helper | [TESTING-v7.4](docs/history/TESTING-v7.4.md) |
| v7.5 | Compressed RTP/SBC from `bluetoothd` to the helper (fixture) | [TESTING-v7.5](docs/history/TESTING-v7.5.md) |
| v7.6 | Decode captured SBC and play it from the helper | [TESTING-v7.6](docs/history/TESTING-v7.6.md) |
| v7.6.1 | Helper playback diagnostics and limited gain | [TESTING-v7.6.1](docs/history/TESTING-v7.6.1.md) |
| v7.7 | Two-phase Sink endpoint capacity trial | [TESTING-v7.7](docs/history/TESTING-v7.7.md) |
| v7.8 | Read-only AVDTP capacity audit | [TESTING-v7.8](docs/history/TESTING-v7.8.md) |
| v7.9 | Read-only allocation geometry audit | [TESTING-v7.9](docs/history/TESTING-v7.9.md) |
| v8.0 | AVDTP configuration lookup timing probe | [TESTING-v8.0](docs/history/TESTING-v8.0.md) |
| v8.1 | One-shot seven-slot AVDTP capacity | [TESTING-v8.1](docs/history/TESTING-v8.1.md) |
| v8.2 | Live native Sink signaling: SEID 7 and SDP `0x110B` | [TESTING-v8.2](docs/history/TESTING-v8.2.md), [PROVENANCE-v8.2](docs/history/PROVENANCE-v8.2.md) |
| v8.3 | Post-Source audio context | [TESTING-v8.3](docs/history/TESTING-v8.3.md) |
| v8.6 | Receive-only media channel trial | [TESTING-v8.6](docs/history/TESTING-v8.6.md) |
| v8.7 | Raw media-handler entry counter | [TESTING-v8.7](docs/history/TESTING-v8.7.md) |
| v8.8 | **Continuous audio**: shared-memory SBC forwarding to the helper | [TESTING-v8.8](docs/history/TESTING-v8.8.md) |
| v8.8.1 | Speaker route | [TESTING-v8.8.1](docs/history/TESTING-v8.8.1.md) |
| v8.8.2 | Native idle-check guard | [TESTING-v8.8.2](docs/history/TESTING-v8.8.2.md) |
| v8.9 | One-tap Start/Stop and audio output selection | [TESTING-v8.9](docs/history/TESTING-v8.9.md) |
| v8.9.1 | Superseded by v8.9.2 (its restart approach was wrong) | [TESTING-v8.9.1](docs/history/TESTING-v8.9.1.md) |
| v8.9.2 | Start reaches the tweak; Bluetooth toggles are detected | [TESTING-v8.9.2](docs/history/TESTING-v8.9.2.md) |
| v8.9.3 | Logs that cover the whole session and show where the audio went | [TESTING-v8.9.3](docs/history/TESTING-v8.9.3.md) |
| v8.9.4 | Wired earbuds without replugging; switching outputs without reconnecting the PC | [TESTING-v8.9.4](docs/history/TESTING-v8.9.4.md) |
| v9.0 | Renamed to Speaka throughout: package `com.parv.speaka`, new setting and notification names | [TESTING-v9.0](docs/history/TESTING-v9.0.md) |

Reverse-engineering findings:

| Document | Topic |
| --- | --- |
| [V5_STATIC_FINDINGS](docs/research/V5_STATIC_FINDINGS.md) | Static disassembly landmarks |
| [V6_SDP_AND_MEDIA_PLAN](docs/research/V6_SDP_AND_MEDIA_PLAN.md) | Plan for Sink discovery and incoming audio |
| [V7_SDP_REVERSE_ENGINEERING](docs/research/V7_SDP_REVERSE_ENGINEERING.md) | SDP record-add instrumentation, verified statically |
| [V7_1_MEDIA_PATH](docs/research/V7_1_MEDIA_PATH.md) | Receive side: complete RTP packets to stereo PCM |
| [V78_AVDTP_CAPACITY_FINDINGS](docs/research/V78_AVDTP_CAPACITY_FINDINGS.md) | `AVDTP_RegisterMultipoint`: the origin of error `0x68` |
| [V79_AVDTP_ALLOCATION_FINDINGS](docs/research/V79_AVDTP_ALLOCATION_FINDINGS.md) | Where the six-entry AVDTP table comes from |
| [V83_BINARY_PROVENANCE](docs/research/V83_BINARY_PROVENANCE.md) | Audio-context expansion: binary provenance |

## Credits

- [Google libsbc](https://github.com/google/libsbc) (Apache-2.0) decodes the audio. It is fetched at build time at commit
  `6e505650145c9973d08a0bdd5e5f5e1914305e40` and is not committed.
- `sbc_decode.c` is the project's own SBC decoder, written from the Bluetooth specification. It is used by the tests and the fixture
  paths.
- The Speaka app's user interface is adapted from [Dopamine](https://github.com/opa334/Dopamine) by Lars Fröder
  (opa334) and its contributors, under the MIT License, which ships in the app and appears under **Credits**.
- Built with [Theos](https://theos.dev). It runs on Dopamine with ElleKit and PreferenceLoader.
