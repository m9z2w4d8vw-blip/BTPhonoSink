# Speaka v8.0 — read-only AVDTP configuration lookup timing probe

## Purpose

v7.9 observed `config=(6,3,3)` and `live=(6,3,3)`. This update tests whether
`bluetoothd`'s config-getter call for index 3 happens after the tweak loads and
whether the call returns the same pointer the existing read-only table audit saw.
**No memory changes, no new Sink endpoint, no SDP publishing, no Bluetooth receiving.**

## Testing

1. Apply the small patch in the correct GitHub folders, commit, and ensure the
   Actions rootless package build succeeds. Preserve working v7.9 `.deb`.
2. Install through Sileo. First leave **Legacy Sink OFF**, **SDP trace OFF**, and
   **Trace AVDTP config lookup (advanced) OFF**. Confirm 5 original hooks, 6
   native Source registrations, and Bluetooth headphone playback works.
3. Optionally enable ONLY **Trace AVDTP config lookup (advanced)**. This adds a
   read-only pass-through hook on an undocumented routine; it is experimental.
4. Restart Bluetooth once from PowerShell (update IP if it changed):

   `ssh -t mobile@10.5.82.212 "sudo killall -9 bluetoothd"`

5. Check the log for `V80_CFG_GET installed` and ideally
   `V80_CFG_GET index=3 ... bytes=(6,3,3) matches_table=yes`.
   Continue to require `V78_TABLE slots=6 occupied=6` and
   `V79_ALLOC config=(6,3,3) live=(6,3,3)`.
6. Confirm real headphone playback still works. Export the log to iCloud Drive.
7. Turn the advanced config observer OFF and restart `bluetoothd` one more time.

`NO_INDEX3_CALL_OBSERVED` is not proof the function is never used; it may have
been called before the hook loaded. Also, an observed index-3 lookup does not,
by itself, prove that the caller was the AVDTP constructor; other parts of the
daemon can request configuration index 3. The hook logs at most four index-3 calls,
leaving all pointers and return values unchanged. This test **does not** establish
that safely patching configuration is possible.

## Recovery

If there is instability, toggle the observer OFF, restart bluetoothd once,
and restore v7.9 if necessary. Do NOT enable Legacy Sink. Do NOT enable the
v7.7 extra endpoint trial.
