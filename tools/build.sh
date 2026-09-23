#!/usr/bin/env bash
# Build the shippable watch face for every fenix 6 product, and refuse to hand back
# anything that would not fit on the watch.
#
# Always builds with -r. A debug build embeds roughly 90 KB of symbol table, which
# overflows the 98304-byte watch-face pool on fenix6s and fenix6spro outright. Those
# symbols are never loaded by the device, so a debug .prg is useless for sideloading
# and actively misleading to have sitting in build/.
set -euo pipefail

SDK="${SDK:-$HOME/.Garmin/ConnectIQ/Sdks/connectiq-sdk-lin-9.2.0}"
KEY="${KEY:-$HOME/.Garmin/ConnectIQ/developer_key.der}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICES=(fenix6 fenix6pro fenix6s fenix6spro fenix6xpro)

[ -x "$SDK/bin/monkeyc" ] || { echo "no monkeyc at $SDK/bin/monkeyc" >&2; exit 1; }
[ -f "$KEY" ] || { echo "no developer key at $KEY" >&2; exit 1; }

cd "$ROOT"
rm -rf build
mkdir -p build

for d in "${DEVICES[@]}"; do
    "$SDK/bin/monkeyc" -d "$d" -f monkey.jungle -o "build/$d.prg" -y "$KEY" -r -w -l 3
done
"$SDK/bin/monkeyc" -f monkey.jungle -o build/solana-epoch.iq -y "$KEY" -e -r -w -l 3

echo
echo "Release artifacts, checked against each device's own watchFace memory pool:"
status=0
for d in "${DEVICES[@]}"; do
    limit=$(python3 -c "
import json
c = json.load(open('$HOME/.Garmin/ConnectIQ/Devices/$d/compiler.json'))
print({a['type']: a['memoryLimit'] for a in c['appTypes']}['watchFace'])")
    size=$(stat -c %s "build/$d.prg")
    if [ "$size" -ge "$limit" ]; then
        printf '  %-11s %7d bytes  OVER the %d byte budget\n' "$d" "$size" "$limit"
        status=1
    else
        printf '  %-11s %7d bytes  %s of the %d byte budget\n' "$d" "$size" \
            "$(python3 -c "print(f'{100*$size/$limit:.1f}%')")" "$limit"
    fi
done
printf '  %-11s %7d bytes  store package\n' "solana-epoch.iq" "$(stat -c %s build/solana-epoch.iq)"

if [ "$status" -ne 0 ]; then
    echo
    echo "At least one build does not fit. Do not sideload these." >&2
fi
exit "$status"
