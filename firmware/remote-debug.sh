#!/usr/bin/env bash
# Debug a board on the Pi with GDB on this machine.
#
#   ./remote-debug.sh <elf> [extra gdb args...]
#   e.g. ./remote-debug.sh target/thumbv6m-none-eabi/release/my-fw -ex 'hbreak main'
#
# Starts `ectf.sh $ECTF_BOARD debug` (OpenOCD) on the Pi, tunnels its
# localhost-only GDB port here over SSH, and runs GDB on the local ELF so you
# get symbols and source. Quitting GDB resumes the board, stops OpenOCD and
# releases the board. The ELF must be the build that's on the board: flash
# it first (`cargo run --release` / ./remote-flash.sh); GDB `load` is
# disabled on purpose (flashing goes through the eCTF bootloader).
#
# GDB: gdb-multiarch, arm-none-eabi-gdb, or a multi-arch `gdb` (Fedora's is).
# Breakpoints are hardware-only: the Cortex-M0+ has 4 (+2 watchpoints).
# `monitor reset halt` stops at the bootloader's reset vector; `continue` then
# runs the bootloader into the app.
set -euo pipefail

PI="${ECTF_PI:-ectf@100.92.231.53}"     # Tailscale (LAN: 10.37.1.253)
BOARD="${ECTF_BOARD:-board1}"
REMOTE_SCRIPT="${ECTF_REMOTE_SCRIPT:-~/ectf2027/ectf.sh}"
if [[ $# -lt 1 || "$1" == -* ]]; then
  echo "usage: $0 <elf> [extra gdb args...]   (the ELF you flashed, e.g. target/thumbv6m-none-eabi/release/<crate>)" >&2
  exit 2
fi
ELF="$1"; shift
GDB="${ECTF_GDB:-$(command -v gdb-multiarch || command -v arm-none-eabi-gdb || echo gdb)}"

[[ -f "$ELF" ]] || { echo "error: ELF not found: $ELF" >&2; exit 1; }

PORT="$(ssh "$PI" "$REMOTE_SCRIPT $BOARD gdbport")"
LOCAL_PORT="${ECTF_LOCAL_PORT:-$PORT}"
LOG="$(mktemp)"

# Own session (setsid) so Ctrl-C in GDB interrupts the target, not the tunnel.
# -tt so killing the tunnel hangs up the remote side and OpenOCD exits.
setsid ssh -tt -o ExitOnForwardFailure=yes -L "$LOCAL_PORT:127.0.0.1:$PORT" \
  "$PI" "ECTF_USER=$(printf %q "${ECTF_USER:-${USER:-dev}}") ${ECTF_FORCE:+ECTF_FORCE=1} $REMOTE_SCRIPT $BOARD debug" < /dev/null > "$LOG" 2>&1 &
SSH_PID=$!
trap 'rc=$?; kill "$SSH_PID" 2>/dev/null; wait "$SSH_PID" 2>/dev/null || true; rm -f "$LOG"; exit $rc' EXIT

for _ in $(seq 100); do
  grep -q "ectf: gdb server ready" "$LOG" && break
  if ! kill -0 "$SSH_PID" 2>/dev/null || grep -q -E "^error:" "$LOG"; then
    grep -E "^error:|Error:" "$LOG" >&2 || cat "$LOG" >&2
    exit 1
  fi
  sleep 0.2
done
grep -q "ectf: gdb server ready" "$LOG" || { echo "error: OpenOCD did not come up:" >&2; cat "$LOG" >&2; exit 1; }

echo "$BOARD: attached via localhost:$LOCAL_PORT -> $PI"
"$GDB" -q "$ELF" -ex "target extended-remote :$LOCAL_PORT" "$@"
