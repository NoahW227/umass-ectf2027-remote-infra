#!/usr/bin/env python3
"""Erase + flash + start an unprotected image through the MITRE eCTF bootloader.

Equivalent to `ectf hw PORT reflash IMAGE -n NAME`, plus a workaround for the
insecure bootloader 26.0.1: its VERIFY step only CRCs the first (size & 0xFFFF)
bytes, so every image >= 64 KiB is rejected with VERIFY_FAILED even though all
chunks were programmed (confirmed by a test app that read 100 KiB back from
flash). For those versions we send the CRC the bootloader actually computes.

Usage: flash.py PORT IMAGE [-n NAME]
"""

import argparse
import struct
import sys
import time

from ectf.hw.bootloader import BootloaderError
from ectf.hw.ti import MSPM0L2228, Image
from ectf.hw.ti.protocol import crc32

# Bootloader versions whose VERIFY truncates the image size to 16 bits.
TRUNCATING_VERSIONS = {(26, 0, 1)}


def connect(board: MSPM0L2228, attempts: int = 3) -> None:
    """CONNECT, flushing leftover app output from the UART before each try"""
    for attempt in range(attempts):
        time.sleep(0.2)
        board.ser.reset_input_buffer()
        try:
            board.connect()
            return
        except BootloaderError:
            if attempt == attempts - 1:
                raise


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("port")
    ap.add_argument("image")
    ap.add_argument("-n", "--name", default="app", help="label the bootloader stores (max 8 bytes)")
    args = ap.parse_args()

    with open(args.image, "rb") as f:
        data = f.read()
    if data.startswith(b"\x7fELF"):
        sys.exit("error: that is an ELF; flash the .bin (rust-objcopy -O binary)")

    board = MSPM0L2228.from_port(args.port, timeout=3)
    try:
        connect(board)
        st = board.status()
        ver = (st.year, st.major_version, st.minor_version)
        print(f"bootloader {'.'.join(map(str, ver))}, secure={bool(st.secure)}")
        if st.secure:
            sys.exit("error: secure (attack-board) bootloader; it only accepts protected images")

        crc_len = len(data) & 0xFFFF if ver in TRUNCATING_VERSIONS else len(data)
        image = Image(args.name, len(data), False, struct.pack("<I", crc32(data[:crc_len])), data)

        print(f"erasing, then flashing {len(data)} bytes as '{args.name}'")
        board.erase()
        board.flash(image)
        board.start()
    except BootloaderError as e:
        sys.exit(f"error: {e} (is the board in update mode?)")
    print("flashed and started")


if __name__ == "__main__":
    main()
