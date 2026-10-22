#!/usr/bin/env bash
# Remote control for eCTF MSPM0L2228 boards on a Raspberry Pi 2B.
#
# Usage:
#   ectf.sh list                     # boards, claims, live activity (= boardctl.py status)
#   ectf.sh <board> reset            # pulse NRST (boots normally)
#   ectf.sh <board> bootloader       # hold PB21 + pulse NRST -> eCTF bootloader
#   ectf.sh <board> status           # bootloader + print bootloader status + reboot
#   ectf.sh <board> flash <image>    # bootloader + flash over UART + reboot
#   ectf.sh <board> debug            # OpenOCD GDB server on 127.0.0.1:<gdb_port> until Ctrl-C
#   ectf.sh <board> port | gdbport   # print the board's serial port / GDB port
#
# Every action except port/gdbport holds the board's lock for its whole run
# (a debug session holds it until it ends). Set ECTF_USER to your name: it
# labels you in `list` / the dashboard, and a board claimed by someone else
# (boardctl.py claim) is refused unless ECTF_USER matches the claim or
# ECTF_FORCE=1 (logged). remote-flash.sh / remote-debug.sh pass ECTF_USER.
# ECTF_IMAGE_NAME (1-8 chars of A-Z a-z 0-9 . _ -, default "app") is the
# label the bootloader stores for a flashed image; remote-flash.sh sends the
# ELF's file name.
#
# Pins are driven "open-drain style": output-low = button pressed,
# input with no pull = released. Pins are never driven high, so pressing the
# physical button at the same time is harmless.
#
# Requires: pinctrl (included in Raspberry Pi OS), flock (util-linux), openocd,
# bwrap (bubblewrap), and the ectf tools in $SCRIPT_DIR/.venv:
#   ~/.local/bin/uv venv ~/ectf2027/.venv && ~/.local/bin/uv pip install -p ~/ectf2027/.venv ectf==2026.0.11

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONF="${ECTF_CONF:-$SCRIPT_DIR/boards.conf}"

# Pinned venv instead of uvx: no resolver run per flash, works offline.
VENV="${ECTF_VENV:-$SCRIPT_DIR/.venv}"
ECTF="$VENV/bin/ectf"

# Flash command. {port}, {image} and {name} are substituted.
# flash.py = erase + flash + start, with the bootloader 26.0.1 >=64 KiB verify fix.
DEFAULT_FLASH_CMD="$VENV/bin/python $SCRIPT_DIR/flash.py {port} {image} -n {name}"
FLASH_CMD="${ECTF_FLASH_CMD:-$DEFAULT_FLASH_CMD}"

OPENOCD_CFG="$SCRIPT_DIR/openocd/mspm0-safe.cfg"
BOARDCTL="$SCRIPT_DIR/boardctl.py"

# Timings (seconds)
RESET_PULSE=0.1     # how long NRST is held low
BOOT_HOLD=0.3       # how long PB21 stays held after reset is released
BOOT_SETTLE=0.5     # wait before talking to the bootloader

die() { echo "error: $*" >&2; exit 1; }

press()   { pinctrl set "$1" op dl; }   # output, driven low
release() { pinctrl set "$1" ip pn; }   # input, no pull (high-Z)

# Board lines with comments stripped: name port nrst pb21 gdb_port
boards() { sed 's/#.*//' "$CONF" | awk 'NF'; }

lookup() {
  local name="$1"
  [[ -f "$CONF" ]] || die "config not found: $CONF"
  read -r PORT NRST PB21 GDB_PORT < <(boards | awk -v n="$name" '$1==n {print $2, $3, $4, $5; exit}') \
    || die "unknown board '$name' (see: $0 list)"
}

lockfile()  { echo "/tmp/ectf-$1.lock"; }
ownerfile() { echo "/tmp/ectf-$1.owner"; }

# Record what we did for the dashboard; never let bookkeeping break hardware work.
note_event() { python3 "$BOARDCTL" event "$BOARD" "$WHO" "$@" >/dev/null 2>&1 || true; }

# "alice (flash since 14:02)" from the owner file of a board in use
owner_desc() {
  local u a t
  IFS=$'\t' read -r u a t _ < "$(ownerfile "$1")" 2>/dev/null || { echo "another session"; return; }
  echo "$u ($a since $(date -d "@$t" +%H:%M))"
}

cleanup() {
  [[ -n "${NRST:-}" ]] && release "$NRST"
  [[ -n "${PB21:-}" ]] && release "$PB21"
  rm -f "$(ownerfile "$BOARD")"
}

do_reset() {
  press "$NRST"; sleep "$RESET_PULSE"; release "$NRST"
}

do_bootloader() {
  press "$PB21"
  do_reset
  sleep "$BOOT_HOLD"
  release "$PB21"
  sleep "$BOOT_SETTLE"
}

# Discard whatever the old app was still sending when it got reset; stale bytes
# in the tty/XDS110 buffer otherwise break the bootloader's first CONNECT reply.
drain_uart() {
  "$VENV/bin/python" -c 'import serial, sys, time
s = serial.Serial(sys.argv[1], 115200, timeout=0.2); time.sleep(0.2); s.read(65536); s.reset_input_buffer()' "$PORT"
}

need_port() { [[ -e "$PORT" ]] || die "serial port missing: $PORT (probe unplugged?)"; }

# /dev/bus/usb node of the XDS110 that owns $PORT.
usb_node() {
  local tty dev
  tty="$(basename "$(readlink -f "$PORT")")"
  dev="$(readlink -f "/sys/class/tty/$tty/device/..")"
  [[ -r "$dev/devnum" ]] || die "can't find the USB device behind $PORT"
  printf '/dev/bus/usb/%03d/%03d\n' "$(<"$dev/busnum")" "$(<"$dev/devnum")"
}

do_status() {
  need_port
  do_bootloader
  drain_uart
  local out rc=0
  # The design name is NUL-padded; strip that before it reaches the terminal.
  out="$("$ECTF" hw "$PORT" status 2>&1 | tr -d '\000')" || rc=$?
  printf '%s\n' "$out"
  do_reset
  if (( rc == 0 )); then
    note_event status \
      version="$(sed -n 's/.*Version: *//p' <<<"$out")" \
      secure="$(sed -n 's/.*Secure bootloader: *//p' <<<"$out")" \
      design="$(sed -n 's/.*Installed design: *//p' <<<"$out" | sed 's/ *$//')"
  else
    note_event status result=failed
  fi
  return "$rc"
}

do_flash() {
  local image="$1"
  [[ -f "$image" ]] || die "image not found: $image"
  local name="${ECTF_IMAGE_NAME:-app}"
  [[ "$name" =~ ^[A-Za-z0-9._-]{1,8}$ ]] || die "ECTF_IMAGE_NAME must be 1-8 characters of A-Z a-z 0-9 . _ - (got '$name')"
  need_port
  do_bootloader
  drain_uart
  local cmd="${FLASH_CMD//\{port\}/$PORT}"
  cmd="${cmd//\{image\}/$image}"
  cmd="${cmd//\{name\}/$name}"
  echo "+ $cmd"
  local log size
  log="$(mktemp)"; size="$(stat -c %s "$image")"
  if ! bash -c "$cmd" 2>&1 | tee "$log"; then
    note_event flash result=failed size="$size" image="${ECTF_IMAGE:-}"
    rm -f "$log"
    die "flash failed for $BOARD (board left in bootloader; inspect with: $0 $BOARD status)"
  fi
  do_reset
  note_event flash result=ok size="$size" image="${ECTF_IMAGE:-}" design="$name" \
    version="$(sed -n 's/^bootloader \([0-9.]*\),.*/\1/p' "$log")" \
    secure="$(sed -n 's/^bootloader .*secure=\(.*\)$/\1/p' "$log")"
  rm -f "$log"
  echo "flashed $BOARD and rebooted"
}

# All our XDS110s report the same serial number and OpenOCD's xds110 driver
# ignores `adapter usb location`, so it would grab whichever probe it sees
# first. Run it in a mount namespace where /dev/bus/usb only holds this
# board's probe: opening the others fails and the driver skips them.
do_debug() {
  need_port
  [[ -n "${GDB_PORT:-}" ]] || die "no gdb_port for $BOARD in $CONF"
  local node
  node="$(usb_node)"
  echo "$BOARD: OpenOCD GDB server on 127.0.0.1:$GDB_PORT (probe $node); Ctrl-C to stop."
  echo "$BOARD stays locked while this runs. Flashing goes through 'flash', not GDB 'load'."
  note_event debug
  bwrap --die-with-parent --dev-bind / / --tmpfs "$(dirname "$node")" --dev-bind "$node" "$node" -- \
    openocd -f interface/xds110.cfg -f "$OPENOCD_CFG" \
      -c "gdb port $GDB_PORT" -c "bindto 127.0.0.1" -c init \
      -c 'if {![mspm0x.cpu was_examined]} { echo "error: core not reachable over SWD (debug locked? attack board?)"; shutdown error }' \
      -c 'echo "ectf: gdb server ready"'
}

case "${1:-}" in
  ""|-h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  list) exec python3 "$BOARDCTL" status ;;
esac

BOARD="$1"; ACTION="${2:-}"
lookup "$BOARD"

# Read-only queries don't need the board.
case "$ACTION" in
  port)    echo "$PORT"; exit 0 ;;
  gdbport) [[ -n "${GDB_PORT:-}" ]] || die "no gdb_port for $BOARD"; echo "$GDB_PORT"; exit 0 ;;
esac

WHO="${SSH_CLIENT:-local}"; WHO="${ECTF_USER:-${WHO%% *}}"

# Respect claims (everyone is trusted, so this is etiquette, not security).
if reason="$(python3 "$BOARDCTL" check "$BOARD" "$WHO" 2>&1)"; then
  :
elif [[ $? -eq 3 ]]; then
  if [[ "${ECTF_FORCE:-0}" == 1 ]]; then
    echo "warning: $reason; ECTF_FORCE=1, continuing (logged)" >&2
    note_event force action="$ACTION" holder="$(sed -n 's/.* claimed by \(.*\) until .*/\1/p' <<<"$reason")"
  else
    die "$reason. Set ECTF_USER to the claim's name if it's yours, or ECTF_FORCE=1 to override."
  fi
else
  echo "warning: claim check failed ($reason); continuing" >&2
fi

# One user per board at a time; teammates get a clear message instead of a collision.
exec 9>"$(lockfile "$BOARD")"
flock -n 9 || die "$BOARD is busy: $(owner_desc "$BOARD")"
printf '%s\t%s\t%s\t%s\n' "$WHO" "$ACTION" "$(date +%s)" "$$" > "$(ownerfile "$BOARD")"
trap cleanup EXIT

case "$ACTION" in
  reset)      do_reset ;;
  bootloader) do_bootloader; echo "$BOARD should be in bootloader (LED D1 blinking red)" ;;
  status)     do_status ;;
  flash)      [[ -n "${3:-}" ]] || die "usage: $0 $BOARD flash <image>"; do_flash "$3" ;;
  debug)      do_debug ;;
  *)          die "unknown action '$ACTION' (reset | bootloader | status | flash | debug | port | gdbport)" ;;
esac
