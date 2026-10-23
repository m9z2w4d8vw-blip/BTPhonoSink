/*
 * find_media_cb.js — Frida script to identify the AVDTP media data
 * receive callback offset in bluetoothd.
 *
 * Usage (after installing the tweak with hooks 2-6 active):
 *   1. Connect your Legion to the iPhone via Bluetooth as A2DP source.
 *   2. Start playing audio on the Legion.
 *   3. On the iPhone (SSH):
 *        frida -p $(pidof bluetoothd) -l find_media_cb.js
 *   4. Look for the line: "[MEDIA_CB] candidate offset = 0x..."
 *      That offset goes into hook #7 in Tweak.xm.
 */

'use strict';

const BTD_BASE = Process.enumerateModulesSync()
    .find(m => m.name === 'bluetoothd').base;

console.log('[find_media_cb] bluetoothd base:', BTD_BASE);

/* ---- 1. Trace all calls immediately after AVDTP_Start is accepted ---- */

/* Known offset: SetConfigInd_handler = 0x37ae6c */
const setConfigIndAddr = BTD_BASE.add(0x37ae6c);

/* We want to watch every function call that happens within ~5 seconds
 * of SetConfigInd being accepted, filtering for calls where the first
 * argument looks like a BT handle and the second is a large buffer.   */

let watching = false;
let candidates = new Set();

Interceptor.attach(setConfigIndAddr, {
    onEnter(args) {
        console.log('[find_media_cb] SetConfigInd fired — arming media-cb search');
        watching = true;
        setTimeout(() => {
            watching = false;
            console.log('[find_media_cb] Watch window closed.');
        }, 5000);
    }
});

/* ---- 2. Hook the send-data function to understand the buffer layout  ---- */
/* Known offset: A2DP_send_data = 0x380af0 */
const sendDataAddr = BTD_BASE.add(0x380af0);
Interceptor.attach(sendDataAddr, {
    onEnter(args) {
        /* args[0] = self/context, args[1] = data ptr, args[2] = length */
        const len = args[2].toInt32();
        if (len > 0 && len < 4096) {
            console.log(`[find_media_cb] send_data called: len=${len}`);
        }
    }
});

/* ---- 3. Scan call sites during the watch window ---------------------- */
/*
 * Approach: after SetConfigInd fires we know the stream is about to start.
 * We use a Stalker trace on the bluetoothd thread that handled SetConfigInd
 * to find the next function that is called with a buffer of 50-1000 bytes
 * where the data starts with an A2DP RTP syncword context.
 *
 * Because Stalker is expensive, we only run it for 3 seconds.
 */
Interceptor.attach(setConfigIndAddr, {
    onLeave(retval) {
        if (retval.toInt32() !== 0) return; /* only if accepted */

        const tid = Process.getCurrentThreadId();
        console.log(`[find_media_cb] Stalking thread ${tid} for 3s`);

        Stalker.follow(tid, {
            events: { call: true },
            onReceive(events) {
                const reader = new Stalker.EventReader(events);
                for (const ev of reader) {
                    if (ev.type !== 'call') continue;
                    const target = ev.target;
                    const offset = target.sub(BTD_BASE);
                    if (offset.toInt32() > 0 && !candidates.has(offset.toString())) {
                        candidates.add(offset.toString());
                        /* Attach a one-shot probe to check buffer size */
                        try {
                            Interceptor.attach(target, {
                                onEnter(args) {
                                    /* Heuristic: arg1 is a pointer, arg2 is a size
                                     * consistent with an RTP/SBC packet (50-1200 bytes) */
                                    try {
                                        const possibleLen = args[2].toInt32();
                                        if (possibleLen >= 50 && possibleLen <= 1200) {
                                            /* Check if arg1 looks like a real buffer */
                                            const ptr = args[1];
                                            if (!ptr.isNull()) {
                                                const first = ptr.readU8();
                                                /* RTP version field: top 2 bits = 10 → 0x80..0xBF */
                                                if (first >= 0x80 && first <= 0xBF) {
                                                    console.log(
                                                        `\n[MEDIA_CB] *** CANDIDATE FOUND ***\n` +
                                                        `  offset = ${ptr.sub(BTD_BASE)}\n` +
                                                        `  function VA = ${target}\n` +
                                                        `  buffer[0] = 0x${first.toString(16).padStart(2,'0')}\n` +
                                                        `  length arg = ${possibleLen}\n` +
                                                        `  Add this offset as MEDIA_RECV_OFFSET in Tweak.xm hook #7\n`
                                                    );
                                                }
                                            }
                                        }
                                    } catch(e) {}
                                }
                            });
                        } catch(e) {}
                    }
                }
            }
        });

        setTimeout(() => {
            Stalker.unfollow(tid);
            console.log('[find_media_cb] Stalker stopped');
        }, 3000);
    }
});

console.log('[find_media_cb] Ready. Connect Legion as BT source and play audio.');
