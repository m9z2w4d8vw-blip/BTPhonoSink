#!/usr/bin/env bash
set -euo pipefail
# Build-time vendoring only. Runtime on the iPhone has no GitHub/network dependency.
repo=https://github.com/google/libsbc.git
commit=6e505650145c9973d08a0bdd5e5f5e1914305e40
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/btpsaudiohelper/vendor_sbc"
if [[ -f "$out/sbc.c" && -f "$out/sbc.h" && -f "$out/bits.c" && -f "$out/bits.h" && -f "$out/LICENSE" ]]; then
    mkdir -p "$root/layout/usr/share/doc/BTPhonoSink"
    cp "$out/LICENSE" "$root/layout/usr/share/doc/BTPhonoSink/Google-libsbc-LICENSE.txt"
    echo 'Using existing vendored Google SBC source'; exit 0
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git init -q "$work/src"
git -C "$work/src" remote add origin "$repo"
git -C "$work/src" fetch -q --depth 1 origin "$commit"
git -C "$work/src" checkout -q --detach FETCH_HEAD
actual="$(git -C "$work/src" rev-parse HEAD)"
[[ "$actual" == "$commit" ]] || { echo 'Upstream commit mismatch' >&2; exit 1; }
mkdir -p "$out"
cp "$work/src/src/sbc.c" "$work/src/src/bits.c" "$work/src/src/bits.h" "$work/src/include/sbc.h" "$work/src/LICENSE" "$out/"
printf '%s\n' "$actual" > "$out/UPSTREAM_COMMIT"
mkdir -p "$root/layout/usr/share/doc/BTPhonoSink"
cp "$out/LICENSE" "$root/layout/usr/share/doc/BTPhonoSink/Google-libsbc-LICENSE.txt"
echo "Vendored Google SBC $actual into $out"
