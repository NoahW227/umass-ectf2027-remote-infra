#!/usr/bin/env bash
# Cargo runner: `cargo run --release` builds locally, converts the ELF to a
# .bin (same as build.sh), copies it to the board Pi and flashes it over UART
# through the eCTF bootloader.
#
# Setup (local machine, once):
#   cargo install cargo-binutils && rustup component add llvm-tools
#   ssh-copy-id ectf@<pi>              # key auth, so the runner never prompts
# .cargo/config.toml points the thumbv6m runner at this script.
# Per shell:  export ECTF_USER=<your name> ECTF_BOARD=board2  [ECTF_PI=ectf@10.37.1.253 on the LAN]
# ECTF_IMAGE_NAME: label stored by the bootloader (max 8 chars; default: the ELF's file name)
# Claim first for long sessions: ectf-boards claim board2 --for 2h
set -euo pipefail

ELF="$1"
PI="${ECTF_PI:-ectf@100.92.231.53}"     # Tailscale (LAN: 10.37.1.253)
BOARD="${ECTF_BOARD:-board1}"
REMOTE_SCRIPT="${ECTF_REMOTE_SCRIPT:-~/ectf2027/ectf.sh}"

BIN="${ELF}.bin"
rust-objcopy -O binary "$ELF" "$BIN"
echo "built $BIN ($(stat -c %s "$BIN") bytes) -> $PI $BOARD"

# Unique name so two people flashing the same board can't clobber each other's
# upload; the board lock on the Pi then serializes the actual flash.
REMOTE_BIN="/tmp/${USER:-dev}-${BOARD}-$$.bin"
scp -q "$BIN" "$PI:$REMOTE_BIN"

# Who and what, for the dashboard: your name (match your claim) + git commit + image hash.
NAME="${ECTF_USER:-${USER:-dev}}"
LABEL="${ECTF_IMAGE_NAME:-$(basename "$ELF" | tr -c 'A-Za-z0-9._\n-' '_' | cut -c1-8)}"
IMAGE="$(git -C "$(dirname "$ELF")" describe --always --dirty 2>/dev/null || echo nogit) sha256:$(sha256sum "$BIN" | cut -c1-12)"

TTY=(); [[ -t 0 ]] && TTY=(-t)
ssh "${TTY[@]}" "$PI" "ECTF_USER=$(printf %q "$NAME") ECTF_IMAGE=$(printf %q "$IMAGE") ECTF_IMAGE_NAME=$(printf %q "$LABEL") ${ECTF_FORCE:+ECTF_FORCE=1} $REMOTE_SCRIPT $BOARD flash $REMOTE_BIN; rc=\$?; rm -f $REMOTE_BIN; exit \$rc"
