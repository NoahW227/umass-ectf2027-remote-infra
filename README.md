# The Hash Slinging Flasher: Remote eCTF board access

A Raspberry Pi in the cybersec room hosts our MSP-LITO-L2228 boards (TI MSPM0L2228 with the MITRE eCTF bootloader). You build firmware on your own machine, then use this repo's scripts to flash it, debug it with GDB, and talk to it over serial. A shared dashboard shows who is using which board.

| What | Where |
|---|---|
| Dashboard (claims, live activity, history) | http://100.92.231.53:8080 (Tailscale) · http://10.37.1.253:8080 (lab LAN) |
| SSH to the Pi | `ectf@100.92.231.53` (Tailscale) · `ectf@10.37.1.253` (LAN) |

**Once you're set up:**

```sh
export ECTF_USER=yourname ECTF_BOARD=board1
ectf-boards claim board1 --for 2h            # reserve the board
cargo run --release                          # Rust project: build locally, flash on the Pi
./remote-debug.sh target/thumbv6m-none-eabi/release/<your-crate>    # GDB on the board
ectf-boards release board1                   # done
```

## What's in this repo

| Path | For |
|---|---|
| `client/ectf-boards` | CLI to see, claim and release boards |
| `firmware/remote-flash.sh` | flashes an ELF onto a board; also works as a cargo runner |
| `firmware/remote-debug.sh` | starts a remote GDB session on a board |
| `firmware/.cargo/config.toml` | minimal cargo config template (runner + target) |
| `pi/`, `internal_docs/` | the server side, for maintainers only; you don't need these |

---

## 1. Setup (once)

### 1.1 Network access

- **Off-site:** join the Tailscale network. Ask Noah for an invite, then use the `100.92.231.53` address.
- **In the room:** connect to OWS and use the LAN address. You may want to set `ECTF_PI=ectf@10.37.1.253` and `ECTF_DASHBOARD=http://10.37.1.253:8080`.

Check it by opening the dashboard in a browser.

### 1.2 SSH key

Flashing and debugging run over SSH and must not ask for a password. Copy your key to the Pi once; ask the maintainer for the `ectf` password.

```sh
ssh-keygen -t ed25519                       # only if you don't have a key yet
ssh-copy-id ectf@100.92.231.53
ssh ectf@100.92.231.53 '~/ectf2027/ectf.sh list'   # board table, no password prompt
```

### 1.3 Local tools

- **`rust-objcopy`**, which `remote-flash.sh` uses to turn your ELF into a raw binary.
  ```sh
  rustup component add llvm-tools
  cargo install cargo-binutils
  ```
- **For Rust projects:** `rustup target add thumbv6m-none-eabi`
- **A GDB with ARM support:** `gdb-multiarch` (Debian/Ubuntu), the stock `gdb` on Fedora, or `arm-none-eabi-gdb` from the Arm GNU Toolchain.
- **Python 3.10+** for `ectf-boards`.

### 1.4 The board CLI

`client/ectf-boards` is a single Python file with no dependencies. Put it on your `PATH`:

```sh
ln -s "$PWD/client/ectf-boards" ~/.local/bin/ectf-boards
ectf-boards                                 # prints the board table
```

### 1.5 Your name

Everything identifies you by `ECTF_USER`. Use the **same name** on the dashboard, in the CLI and when flashing, or the Pi will treat a board you claimed as someone else's. Put it in your shell profile:

```sh
export ECTF_USER=yourname
export ECTF_BOARD=board1                     # optional: your default board
```

---

## 2. Hooking up your project

### Rust (cargo)

1. Copy `firmware/remote-flash.sh` and `firmware/remote-debug.sh` next to your `Cargo.toml`.
2. Make `cargo run` flash through the Pi. In your project's `.cargo/config.toml`:
   ```toml
   [target.'cfg(all(target_arch = "arm", target_os = "none"))']
   runner = "./remote-flash.sh"

   [build]
   target = "thumbv6m-none-eabi"
   ```
   That's all `firmware/.cargo/config.toml` contains. Merge it into your own config; keep your project's `rustflags` (linker scripts) and `[env]`.

### Anything else (C, Make, …)

Build an ELF, then pass it to the script directly:

```sh
./remote-flash.sh build/app.elf
```

To flash a raw `.bin` you already have, see [Flashing](#5-flashing).

### What the bootloader expects

The eCTF bootloader owns the start of flash and loads your image as a **raw binary** into the application region. Flash layout (from the eCTF 2026 spec):

| Address | Size | Region |
|---|---|---|
| `0x00000` | 24 KiB | eCTF bootloader (don't touch) |
| `0x06000` | 208 KiB | **APP**: your image starts here, vector table first |
| `0x3A000` | 1 KiB | file allocation table (used by eCTF designs) |
| `0x3A400` | 22 KiB | APP2 (free for your design) |
| `0x3FC00` | 1 KiB | reserved by the bootloader |

- Link your firmware so its vector table sits at `0x6000`. `memory.x` for Rust/cortex-m-rt: `FLASH : ORIGIN = 0x00006000`.
- If you use interrupts, point VTOR at `0x6000` early in startup. The UMass firmware writes `0x6000` to `0xE000ED08` first thing in `main`.
- `remote-flash.sh` makes the `.bin` with `rust-objcopy -O binary`. The image runs from its lowest address to its highest, and any gaps are filled with zeros.

---

## 3. Typical session

1. **Look** at the dashboard. Each card shows whether a board is free, who claimed it and until when, and anything running on it right now.
2. **Claim** a board: dashboard **Claim** button, or `ectf-boards claim board1 --for 2h`.
3. **Build and flash:** `cargo run --release` or `./remote-flash.sh your.elf` (about 25–30 s for 200 KB).
4. **Test:** watch the serial console, or run your host-side scripts on the Pi.
5. **Debug** with `./remote-debug.sh` when something's wrong.
6. **Release** the board when you're done.

Quick one-off flashes on an unclaimed board are fine without claiming. Claim anything longer than a few minutes, and always claim before debugging.

---

## 4. Claiming

A claim is your name on a board for a while. There are no accounts: everyone is trusted, and claims are how we coordinate.

| | Dashboard | CLI |
|---|---|---|
| See everything | the page (refreshes every 3 s) | `ectf-boards` |
| Claim | enter your name at the top, pick a duration, optional note, **Claim** | `ectf-boards claim board1 --for 2h --note "testing UART driver"` |
| Extend | **Extend** on your card | claim again: `ectf-boards claim board1 --for 1h` |
| Release | **Release** on your card | `ectf-boards release board1` |
| Take over someone's claim | **force release** (asks to confirm) | `ectf-boards release board1 --force` |

- The default is **2 h** and the maximum **12 h**. Claims expire on their own; claiming a board you already hold extends it. Names are case-insensitive.
- **What's enforced:** flash, debug, reset and status on a board claimed by someone else are refused:
  ```
  error: board1 is claimed by alice until 15:30. Set ECTF_USER to the claim's name if it's yours, or ECTF_FORCE=1 to override.
  ```
- **Overrides:** setting `ECTF_FORCE=1` goes ahead anyway, and the dashboard history records it. Ask first.
- **Unclaimed boards** are open to anyone. Two actions still can't hit the same board at once: the second gets `board1 is busy: bob (flash since 14:02)` and nothing happens.

---

## 5. Flashing

```sh
cargo run --release                          # Rust: flashes $ECTF_BOARD (default board1)
ECTF_BOARD=board2 cargo run --release        # another board
./remote-flash.sh path/to/app.elf            # any ELF
```

Successful output looks like this:

```
built target/thumbv6m-none-eabi/release/my-fw.bin (136192 bytes) -> ectf@100.92.231.53 board1
bootloader 26.0.1, secure=False
erasing, then flashing 136192 bytes as 'my-fw'
flashed and started
flashed board1 and rebooted
```

`'my-fw'` is the image's **label**: the bootloader stores it, `status` and the dashboard show it. It defaults to the ELF's file name, cut to 8 characters (the bootloader's limit). Set your own with `ECTF_IMAGE_NAME=v2-test`; allowed characters are letters, digits, `.`, `_` and `-`.

- **Only the binary crosses the network.** Builds always happen on your machine.
- **No buttons needed:** the Pi resets the board into the bootloader, flashes, and reboots it into your firmware.
- **Every flash is recorded on the dashboard:** who, when, the size, and the image as `git describe --dirty` plus a sha256 prefix.
- **Each flash starts with the bootloader's erase of the application region,** so don't expect data your firmware wrote to flash to survive a reflash.

To flash a raw `.bin`:

```sh
PI=ectf@100.92.231.53
scp app.bin $PI:/tmp/$USER.bin
ssh $PI "ECTF_USER=$ECTF_USER ECTF_IMAGE_NAME=my-fw ~/ectf2027/ectf.sh board1 flash /tmp/$USER.bin"
```

Without `ECTF_IMAGE_NAME` the label is `app`.

Other board actions, all on the Pi:

```sh
ssh $PI "ECTF_USER=$ECTF_USER ~/ectf2027/ectf.sh board1 reset"    # reboot the board
ssh $PI "ECTF_USER=$ECTF_USER ~/ectf2027/ectf.sh board1 status"   # bootloader version, secure or not, installed image
```

---

## 6. Serial console

The board's UART (115200 baud, through its XDS110 probe) is a serial port on the Pi. To watch it or type into it:

```sh
ssh -t ectf@100.92.231.53 '~/ectf2027/.venv/bin/python -m serial.tools.miniterm --raw $(~/ectf2027/ectf.sh board1 port) 115200'
```

Quit with `Ctrl+]`. Host-side programs that talk to your firmware over serial also run on the Pi; `$(~/ectf2027/ectf.sh board1 port)` gives them the port.

The serial port isn't covered by claims or locks. Only use it on a board you've claimed, and **close the console before flashing**, because flashing uses the same port.

---

## 7. Debugging

Flash the build you want to debug, then run from your project folder. The ELF argument is required, and it must be the file you just flashed:

```sh
./remote-debug.sh target/thumbv6m-none-eabi/release/<your-crate>    # Rust
./remote-debug.sh build/app.elf                                     # anything else
./remote-debug.sh build/app.elf -ex "hbreak main" -ex continue      # extra GDB arguments
```

This starts OpenOCD for your board on the Pi and tunnels its GDB port to your machine over SSH. Then it opens GDB on your local ELF, so you get your symbols and source. **Quitting GDB cleans up:** the board resumes running, OpenOCD stops, and the board is free again. The ELF must be the exact build that's on the board.

| GDB | What it does |
|---|---|
| `Ctrl-C` | halt the core |
| `bt`, `info registers`, `x/16wx 0x20200000` | inspect |
| `disassemble`, `x/8i $pc`, `stepi`, `nexti` | step through assembly |
| `hbreak <function or *addr>` | breakpoint |
| `watch <expr>` | watchpoint |
| `continue` | resume |
| `monitor reset halt` | reset and stop at the bootloader's first instruction; `continue` runs it into your app |

Limits:

- **4 breakpoints and 2 watchpoints, total.** The Cortex-M0+ only has hardware breakpoints. Plain `break` is converted automatically, but a 5th one fails.
- **`load` and other flash-writing commands are disabled on purpose.** Flash with `remote-flash.sh`. A debugger can rewrite any part of flash, including the bootloader and the chip's configuration area, and some mistakes there are permanent.
- **The board stays locked while you debug.** Nobody can flash it until you quit GDB, so don't leave sessions open.
- **Pausing at a breakpoint stops the firmware dead.** Anything talking to it over serial may time out and leave your firmware waiting for a reply that never comes. `ectf.sh board1 reset` gets you back to a clean state.
- **Other GDB front ends** (e.g. VS Code Cortex-Debug with `servertype: external`) can use the same server through a tunnel you open yourself. This is untested so far:
  ```sh
  ssh -tt -L 3333:127.0.0.1:3333 ectf@100.92.231.53 "ECTF_USER=$ECTF_USER ~/ectf2027/ectf.sh board1 debug"
  ```
  Then point the front end at `localhost:3333`. Each board's GDB port is on the dashboard.

---

## 8. How it works

```
 your machine                          board Pi                                    boards
 ────────────                          ────────                                    ──────
 build ─► ELF ─► remote-flash.sh ─ssh─►  checks the claim, locks the board
                                         ├─ GPIO ─────────── NRST / PB21 ───────►  MSPM0L2228
                                         ├─ eCTF flash tool ─ USB ─► XDS110 UART ►  (eCTF bootloader)
 remote-debug.sh ──ssh tunnel───────────►└─ OpenOCD ──────── USB ─► XDS110 SWD ─►
 browser / ectf-boards ──HTTP :8080─────►  dashboard + claims
```

- **Each board** has a TI XDS110 probe on a USB hub on the Pi. The probe provides a serial port (bootloader and your firmware's UART) and SWD (debugging).
- **Reset without hands.** Two Pi GPIO pins are wired to each board's NRST (reset) and PB21 pins. Holding PB21 low during a reset keeps the board in the eCTF bootloader (update mode). That's how flashing works with nobody pressing buttons.
- **Flashing** goes through MITRE's eCTF bootloader over the serial port: erase, write, verify, start.
- **Debugging** uses OpenOCD with a restricted config: no flash writes and no destructive commands. It listens only on the Pi itself, so you reach it through an SSH tunnel.
- **Claims and locks:** the Pi checks the claim and takes a per-board lock for every action, so two people can't collide. The dashboard shows claims, what's running right now, and a history of claims, flashes and debug sessions.

Current boards (live details on the dashboard):

| Board | Bootloader | Pi GPIO NRST / PB21 | GDB port |
|---|---|---|---|
| board1 | insecure 26.0.1 | 17 / 27 | 3333 |
| board2 | insecure 26.0.2 | 22 / 23 | 3334 |

On board1, MITRE's stock `ectf hw flash` fails for any image of 64 KiB or more because of a bug in bootloader 26.0.1. The Pi's flash tool works around it, so use `remote-flash.sh` rather than the stock command.

Maintainers: the server side is in `pi/`, and the design notes and gotchas are in `internal_docs/`.

---

## 9. Rules

- **Never** run a factory reset, mass erase, or anything that touches the chip's NONMAIN configuration area. These can permanently brick a board or destroy its bootloader. The debug setup blocks them; don't work around it.
- **Attack boards** have the secure bootloader: `status` shows `Secure bootloader: True`. They only accept MITRE-encrypted images and their debug port is locked. Don't try to flash, erase or unlock them; tell the maintainer so the board gets labelled.
- Claim before long sessions, release when done, and ask before using `ECTF_FORCE`.
- Don't move USB cables or GPIO wires on the Pi; tell the maintainer instead.

---

## 10. Troubleshooting

| Message / symptom | Meaning and fix |
|---|---|
| `board1 is claimed by alice until 15:30` | Someone else holds it. Pick another board, ask them, or check that your `ECTF_USER` matches your own claim. |
| `board1 is busy: bob (flash since 14:02)` | Another action is running right now. Wait for it to finish. |
| A password prompt, or `Permission denied (publickey,password)` | Your SSH key isn't on the Pi: see [1.2](#12-ssh-key). |
| `ssh: connect to host ... timed out` | Not on Tailscale / the room LAN, or the Pi is down. Try the dashboard URL. |
| `rust-objcopy: command not found` | Install it: see [1.3](#13-local-tools). |
| `error: Could not connect to the bootloader (is the board in update mode?)` | The board didn't come up in the bootloader. Retry once; if it persists, tell the maintainer. |
| `error: secure (attack-board) bootloader` | It's an attack board: see [Rules](#9-rules). |
| `serial port missing: ... (probe unplugged?)` | The probe isn't connected; the dashboard card shows "probe missing". Tell the maintainer. |
| `error: core not reachable over SWD (debug locked? attack board?)` | The board's debug port is locked. |
| `usage: ./remote-debug.sh <elf>` or `error: ELF not found` | Pass the path of the ELF you flashed as the first argument. |
| GDB can't insert a breakpoint | All 4 hardware breakpoints are in use: `info breakpoints`, then `delete` some. |
| Firmware boots but nothing works | Check it's linked at `0x6000` and sets VTOR: see [What the bootloader expects](#what-the-bootloader-expects). |
| Dashboard says "can't reach the Pi" | Network problem, or the service is down. Tell the maintainer. |

---

## 11. Reference

Environment variables (on your machine):

| Variable | Used by | Default |
|---|---|---|
| `ECTF_USER` | everything; your name | `$USER` |
| `ECTF_BOARD` | `remote-flash.sh`, `remote-debug.sh` | `board1` |
| `ECTF_PI` | `remote-flash.sh`, `remote-debug.sh` | `ectf@100.92.231.53` |
| `ECTF_DASHBOARD` | `ectf-boards` | `http://100.92.231.53:8080` |
| `ECTF_IMAGE_NAME` | `remote-flash.sh`, `ectf.sh flash`; image label stored by the bootloader (max 8 characters) | the ELF's file name (`app` for a raw `.bin`) |
| `ECTF_FORCE=1` | flash/debug/reset/status despite someone else's claim (logged) | off |
| `ECTF_GDB` | `remote-debug.sh`; which GDB to run | auto-detected |
| `ECTF_LOCAL_PORT` | `remote-debug.sh`; local tunnel port if the default is taken | the board's GDB port |

Board commands on the Pi (`ssh ectf@100.92.231.53 "ECTF_USER=you ~/ectf2027/ectf.sh ..."`):

| Command | Does |
|---|---|
| `ectf.sh list` | board table: claims, activity, bootloader, ports |
| `ectf.sh <board> reset` | reboot the board |
| `ectf.sh <board> status` | bootloader version, secure or not, installed image; then reboot |
| `ectf.sh <board> flash <file.bin>` | flash a raw binary |
| `ectf.sh <board> debug` | OpenOCD GDB server until Ctrl-C |
| `ectf.sh <board> port` / `gdbport` | print the serial port / GDB port |

---

## Example: the UMass 2026 eCTF HSM firmware

A complete walkthrough with our 2026 competition firmware (Rust, an HSM that stores files and talks to MITRE's host tools). Use it to check your setup end to end.

**Build setup.** Copy `remote-flash.sh` and `remote-debug.sh` into the UMass repo's `firmware/` folder. Its `.cargo/config.toml` already has `runner = "./remote-flash.sh"`, alongside its own linker flags and the build settings below. The build also needs a secrets file covering every group in `PERMISSIONS`; run this from the repo root:

```sh
uvx --with-editable ./ectf26_design --from ectf26_design secrets \
    firmware/global.secrets 0xbeef 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16
```

The dev build's HSM PIN is `abcdef` (`HSM_PIN` in `.cargo/config.toml`).

**Flash** (from `firmware/`, about 28 s for the 217 KB image; the label will be `ectf-202`, from the ELF name `ectf-2026`):

```sh
ectf-boards claim board1 --for 1h --note "HSM test"
cargo run --release
```

**Talk to the HSM** with MITRE's host tools, which are installed on the Pi:

```sh
PI=ectf@100.92.231.53
T='cd ~/ectf2027 && .venv/bin/ectf tools $(./ectf.sh board1 port)'
ssh $PI "$T list abcdef"                                       # -> List successful
scp hello.txt $PI:/tmp/hello.txt
ssh $PI "$T write abcdef 0 0xbeef /tmp/hello.txt"              # slot 0, group 0xbeef
ssh $PI "mkdir -p /tmp/out && $T read abcdef 0 /tmp/out/"
scp "$PI:/tmp/out/*" .
```

A wrong PIN returns `Invalid pin!`. Every flash erases the files the HSM has stored, because the image covers its file-storage region.

**Debug a command handler.** Break when the HSM receives a host command, then send it one:

```sh
./remote-debug.sh target/thumbv6m-none-eabi/release/ectf-2026
(gdb) hbreak ectf_2026::command::handle_command<ectf_2026::flash::HwFlash>
(gdb) continue
#   in another terminal: ssh $PI "$T list abcdef"
Breakpoint 1, ectf_2026::command::handle_command<...> (cmd=ectf_2026::host::MsgType::List, pkt_len=6, ...) at src/command.rs:53
(gdb) bt
(gdb) quit
```

The host tool will usually time out while you're stopped at the breakpoint. The HSM then waits forever for the tool's acknowledgement. Reset it before the next command: `ssh $PI "ECTF_USER=$ECTF_USER ~/ectf2027/ectf.sh board1 reset"`.
