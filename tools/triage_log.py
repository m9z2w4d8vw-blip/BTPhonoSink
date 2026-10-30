#!/usr/bin/env python3
"""Offline interpreter for Speaka v5/v6 exported Settings logs.

This utility *does not* access an iPhone or modify Bluetooth. Its conclusions
are conservative, distinguish observation from implementation, and use no cloud.
"""
import argparse
import re
from pathlib import Path


def assess(text: str) -> dict:
    events = text.split('== LOG (from ', 1)[-1] if '== LOG (from ' in text else text
    build = re.search(r'^build:\s*(.+)$', text, re.M)
    installed = len(re.findall(r'^hook\.[^:]+:\s*installed\s*$', text, re.M))
    accepted = re.findall(r'(?:(?:v5: native A2DP Source|TRACE native A2DP Source) #)(\d+) accepted', events)
    failed = re.findall(r'(?:native Source registration FAILED|FAIL native Source registration)', events)
    source_seids = re.findall(r'Source #\d+ accepted \(SEID=(\d+)\)', events)
    return {
        'build': build.group(1) if build else 'unknown',
        'installed_hooks': installed,
        'source_success_seen': len(accepted),
        'source_seids': [int(x) for x in source_seids],
        'native_source_failures': len(failed),
        'seen_setconfig': bool(re.search(r'SetConfigInd_handler call #', events)),
        'seen_sbc_accept': bool(re.search(r'SetConfig_accept_SBC call #', events)),
        'seen_publish_audio': bool(re.search(r'publish_audio_device call #', events)),
        'sdp_110b_published_by_project': False,
        'receive_path_implemented': False,
        'v4_experiment_in_log': 'EXPERIMENT: sink registration returned' in events,
    }


def summary(a: dict) -> str:
    out = [f"Build: {a['build']}", f"Hooks installed: {a['installed_hooks']}/5",
           f"Native Source registrations logged as accepted: {a['source_success_seen']}",
           f"SEIDs observed: {a['source_seids']}",
           f"Registration failures logged: {a['native_source_failures']}",
           f"Configuration callback observed: {a['seen_setconfig']}",
           f"SBC acceptance callback observed: {a['seen_sbc_accept']}",
           f"Audio-device callback observed: {a['seen_publish_audio']}"]
    if a['native_source_failures']:
        out.append('ATTENTION: native endpoint registration failed; compare with safe v5 baseline.')
    if a['v4_experiment_in_log']:
        out.append('ATTENTION: captured lines include v4 sink mirroring; verify PID/session before inferring current state.')
    out.append('Sink SDP 0x110B: NOT implemented by the project; logs alone cannot prove remote SDP visibility.')
    out.append('Incoming A2DP media decode/playback: NOT implemented by the project.')
    return '\n'.join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('exported_log', type=Path)
    args = ap.parse_args()
    print(summary(assess(args.exported_log.read_text(encoding='utf-8', errors='replace'))))


if __name__ == '__main__':
    main()
