# v5 on-device test — exact checklist

This v5 build is intentionally **observe-only**. It does **not** make Windows see the iPhone as a Bluetooth speaker yet. It tests native Source endpoint preservation and logs SEIDs without overflowing the six-slot table.

## Upload & build

1. Extract the `Speaka-v5-updated-repository.zip` on your Windows computer. Do **not** upload this ZIP as a file in your GitHub repo; commit the contents of its `Speaka-main` directory to the root of the repo.
2. Commit and push to `main`. The existing GitHub Actions `build` workflow starts automatically and runs Python safety/SDP tests, the Theos build, and `.deb` package verification.
3. In GitHub **Actions > build > your most recent run**, wait for **Build .deb** and **Publish to GitHub Releases** to be successful. If red, copy the failed job log rather than installing an old release.
4. In **Releases > nightly**, open the updated release and download the new `.deb`. Check its commit matches your push. Do not use **Source code (zip)**: it is not installable.

## On your jailbroken iPhone 13, iOS 17 (Dopamine)

1. Before installing, open **Settings > Speaka** and leave **Legacy sink experiment flag** OFF (it was called **Enable sink experiments** in v4).
2. Use your normal package installation flow to install the newly released `.deb` (e.g. download from GitHub Releases, open using Filza/Sileo, confirm upgrade).
3. If the package manager prompts for restart/reboot, follow it. If the daemon doesn't reload, reboot normally and **re-jailbreak** with Dopamine. Do not force-kill `bluetoothd` repeatedly if it crashes.
4. Reopen **Settings > Speaka**, check **Loaded in daemon: Yes**.
5. Tap **View debug log** and look for the `Speaka v5-safe-observe` startup line. `hooks: 5 installed, 0 not installed` is the desired result.
6. The latest v5 lines should contain `native A2DP Source #1 accepted` through `#6 accepted`, with `SEID=1` to `SEID=6` typically, and `six native Source endpoints registered; six-slot table is occupied; Sink injection skipped`.
7. Confirm you see **no** `v5: native Source registration FAILED` and **no** old v4 `EXPERIMENT: registering a SINK endpoint` messages from the current daemon session. Older logs can persist: compare timestamps and the build tag.
8. Verify Bluetooth still works in its **normal iPhone-to-headphones direction** if you have compatible headphones. Do not re-pair Windows to try to play audio *to* the iPhone: no Sink SDP service exists in v5.
9. Tap **Copy log to clipboard**, save/paste the complete log, and send it back together with the GitHub Actions run link and whether normal Bluetooth worked.

## Expected outcomes

- **Pass**: 5 hooks installed; successful native Source registration(s); no injected Sink; normal Bluetooth still works.
- **Fail**: `0x68` for a native Source in v5, fewer native registrations when six are expected, hook mismatch, daemon crash/restart loop, or Bluetooth no longer operates normally.
- **Not a v5 test**: Seeing an iPhone `AudioEndpoint` or hearing audio from Windows. These require later unimplemented SDP publication and audio receive/playback work.

## Rollback

If Bluetooth becomes unstable, disable or uninstall `com.parv.speaka` in Sileo or with your supported tweak-safe-mode tools, and restart/re-jailbreak normally. Preserve the v5 log if possible. Avoid installing unknown `.deb` files from other release runs.
