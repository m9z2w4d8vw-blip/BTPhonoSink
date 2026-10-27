# v8.1 One-shot AVDTP capacity experiment — carefully follow this order

**This experimental code is not verified by an iOS device test.** It intercepts an undocumented initialization function, and may crash/restart `bluetoothd`. Keep a working v8.0 .deb and SSH access.

1. Upload updated files, keeping their paths including `BTPSV81Config.c/.h`, through your GitHub repo. Confirm Actions builds successfully; do not install on build failure.
2. Install .deb. Confirm `v8.1-one-shot-seven-slot` in Debug log.
3. With **Arm seven slots for ONE restart OFF**, keep **Legacy Sink OFF**, **Trace SDP OFF**, **Trace AVDTP config lookup OFF**. Restart bluetoothd if needed and verify 5 hooks, six native Sources, 6/6 endpoint slots and normal headphone sound. Export this baseline log.
4. Only after confirming baseline, switch **Arm seven slots for ONE restart ON**; leave other switches OFF.
5. Run `ssh -t mobile@10.5.82.212 "sudo killall -9 bluetoothd"` in Windows PowerShell (IP may change).
6. Open Debug log and look for `V81_CFG ARM CONSUMED` and `V81_CFG SHADOW`, then `V78_TABLE RESULT slots=7 occupied=6 free=1`, `V79_ALLOC RESULT config=(6,3,3) live=(7,3,3)` (expected mismatch because original config pointer remains untouched). Verify headphones connect AND audibly play.
7. Verify Settings switch has reset to OFF. **Do not re-arm immediately.** Export the log and send it for review.
8. Return to normal baseline with one more `bluetoothd` restart (arm should stay OFF). Confirm table returns to 6/6 and headphones work.

**Stop/rollback:** If Bluetooth is unstable, ensure the one-shot switch is OFF and restart `bluetoothd`. If it continues to fail, restore the v8.0 package through Sileo / safe mode and reboot-jailbreak as required. Never enable Legacy Sink. A seven-slot readout alone proves allocation capacity only; it does not mean an extra Sink can register or Windows can send audio.

**Design specifics:** Exact `bluetoothd` UUID and initializer signatures checked before installing getter hook. A one-shot preference is cleared and synchronized before trial. The getter may return a static aligned 32-byte copy of the original immutable index-3 config with only byte 0 changed 6→7, only on its first validated index-3 access. The original config, allocator, and native registrations are never modified. Active getter hook is excluded from the late signature scan only if its original instruction signatures were verified before installation; all other initializer instruction checks remain live.

**Scope:** This build makes no Sink service announcement and has no Sink registration code. Bluetooth receive still does not exist.
