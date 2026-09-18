#!/usr/bin/env bash
# build.sh — assemble a Z80 source file and wrap it as a .VZ autostart binary
# Linux equivalent of build.ps1.
#
# Usage:  ./build.sh src/vzdoom.asm VZDOOM
#         ./build.sh <source.asm> <NAME> [load_addr_hex]   (default 7AE9)
#
# Output: build/<NAME>.VZ  (24-byte VZF1 header + binary, type F1 autostart)
# The source must SAVEBIN to build/<basename>.bin (see the .asm files).
#
# Requires sjasmplus on PATH, or a copy in tools/sjasmplus next to this script.

set -euo pipefail

SOURCE="${1:?Usage: ./build.sh <source.asm> <NAME> [load_addr_hex]}"
NAME="${2:?Usage: ./build.sh <source.asm> <NAME> [load_addr_hex]}"
LOADADDR="${3:-7AE9}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if [ "${#NAME}" -gt 8 ]; then
    echo "Error: .VZ filenames are limited to 8 characters" >&2
    exit 1
fi

# ── Locate sjasmplus ─────────────────────────────────────────────────────────
SJ=""
if command -v sjasmplus >/dev/null 2>&1; then
    SJ="$(command -v sjasmplus)"
elif [ -x "$ROOT/tools/sjasmplus" ]; then
    SJ="$ROOT/tools/sjasmplus"
else
    echo "Error: sjasmplus not found on PATH or in tools/sjasmplus." >&2
    echo "Build it from https://github.com/z00m128/sjasmplus (make USE_LUA=0)" >&2
    echo "or install it via your distro's package manager, then re-run." >&2
    exit 1
fi

# ── Assemble ──────────────────────────────────────────────────────────────────
mkdir -p build
"$SJ" "$SOURCE"

BASENAME="$(basename "${SOURCE%.*}")"
BINPATH="build/${BASENAME}.bin"
if [ ! -f "$BINPATH" ]; then
    echo "Error: expected assembler output not found: $BINPATH" >&2
    exit 1
fi

# ── VZ header: 'VZF1' + name[17] + type F1 + load address LE ─────────────────
OUTPATH="build/${NAME^^}.VZ"
python3 - "$BINPATH" "$OUTPATH" "$NAME" "$LOADADDR" <<'PYEOF'
import sys
binpath, outpath, name, loadaddr_hex = sys.argv[1:5]
name = name.upper()
loadaddr = int(loadaddr_hex, 16)

code = open(binpath, "rb").read()

header = bytearray(24)
header[0:4] = b"VZF1"
header[4:4+len(name)] = name.encode("ascii")
header[21] = 0xF1                              # binary / autostart
header[22] = loadaddr & 0xFF                   # load address, little-endian
header[23] = (loadaddr >> 8) & 0xFF

with open(outpath, "wb") as f:
    f.write(bytes(header) + code)

print()
print(f"Built {outpath}")
print(f"  code  : {len(code)} bytes at 0x{loadaddr:04X}")
print(f"  total : {24 + len(code)} bytes")
PYEOF
