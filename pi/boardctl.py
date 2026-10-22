#!/usr/bin/env python3
"""Board reservations and status for the eCTF board Pi: CLI + web dashboard.

  boardctl.py status [--json]
  boardctl.py claim   <board> <name> [--for 2h] [--note TEXT]
  boardctl.py release <board> <name> [--force]
  boardctl.py check   <board> <name>     # exit 0 if <name> may use <board>, 3 if claimed by someone else
  boardctl.py event   <board> <name> <kind> [key=value ...]
  boardctl.py serve   [--host 0.0.0.0] [--port 8080]

Everyone is trusted: a claim is just a name. Claims expire on their own;
claiming a board you already hold extends it. ectf.sh refuses hardware
actions on a board claimed by someone else (ECTF_FORCE=1 overrides, logged).

State lives in ./state/ next to this file: claims.json, boards.json (last
bootloader status / last flash per board) and events.jsonl (history).
Live activity comes from the owner files ectf.sh writes while it holds a
board (/tmp/ectf-<board>.owner: user, action, start epoch, pid).

Stdlib only, so it runs on the Pi's system python3.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import re
import sys
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONF = Path(os.environ.get("ECTF_CONF", HERE / "boards.conf"))
STATE = Path(os.environ.get("ECTF_STATE", HERE / "state"))
DASHBOARD_HTML = HERE / "dashboard.html"

DEFAULT_CLAIM_S = 2 * 3600
MAX_CLAIM_S = 12 * 3600
MAX_NAME = 32
MAX_NOTE = 80
EVENTS_SHOWN = 40


class ClaimError(Exception):
    """A claim/release request that can't be honoured (HTTP 409 / exit 3)"""


# ─── boards.conf ────────────────────────────────────────────────────


def read_boards() -> list[dict]:
    """Board lines with comments stripped: name port nrst pb21 [gdb_port]"""
    boards = []
    for raw in CONF.read_text().splitlines():
        line = raw.split("#", 1)[0].split()
        if len(line) < 4:
            continue
        name, port, nrst, pb21, *rest = line
        boards.append({
            "name": name, "port": port, "nrst": int(nrst), "pb21": int(pb21),
            "gdb_port": int(rest[0]) if rest else None,
        })
    return boards


def board_names() -> list[str]:
    return [b["name"] for b in read_boards()]


# ─── state files ────────────────────────────────────────────────────


@contextlib.contextmanager
def state_lock():
    """Serialize read-modify-write of the state files across processes"""
    STATE.mkdir(parents=True, exist_ok=True)
    with open(STATE / ".lock", "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def _load(name: str) -> dict:
    try:
        return json.loads((STATE / name).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _save(name: str, data: dict) -> None:
    tmp = STATE / f".{name}.tmp"
    tmp.write_text(json.dumps(data, indent=1, sort_keys=True))
    tmp.replace(STATE / name)


def _append_event(ev: dict) -> None:
    with open(STATE / "events.jsonl", "a") as f:
        f.write(json.dumps(ev, sort_keys=True) + "\n")


def recent_events(n: int = EVENTS_SHOWN) -> list[dict]:
    try:
        lines = (STATE / "events.jsonl").read_text().splitlines()
    except FileNotFoundError:
        return []
    out = []
    for line in reversed(lines[-n:]):
        with contextlib.suppress(json.JSONDecodeError):
            out.append(json.loads(line))
    return out


def _live_claims(claims: dict, now: float) -> dict:
    return {b: c for b, c in claims.items() if c.get("until", 0) > now}


def active_claims(now: float | None = None) -> dict:
    return _live_claims(_load("claims.json"), now or time.time())


# ─── validation ─────────────────────────────────────────────────────


def clean_name(name: str) -> str:
    name = " ".join(str(name).split())
    if not name or len(name) > MAX_NAME or not name.isprintable():
        raise ClaimError(f"name must be 1-{MAX_NAME} printable characters")
    return name


def same_person(a: str, b: str) -> bool:
    return a.casefold() == b.casefold()


def parse_duration(text: str) -> int:
    """'90', '90m', '2h', '1h30m' -> seconds (bare number = minutes)"""
    text = str(text).strip().lower()
    if text.isdigit():
        return int(text) * 60
    m = re.fullmatch(r"(?:(\d+)h)?\s*(?:(\d+)m)?", text)
    if not m or not any(m.groups()):
        raise ClaimError(f"bad duration '{text}' (use e.g. 45m, 2h, 1h30m)")
    return int(m[1] or 0) * 3600 + int(m[2] or 0) * 60


def _check_board(board: str) -> None:
    if board not in board_names():
        raise ClaimError(f"unknown board '{board}' (have: {', '.join(board_names())})")


# ─── operations ─────────────────────────────────────────────────────


def claim(board: str, name: str, seconds: int = DEFAULT_CLAIM_S, note: str = "") -> dict:
    _check_board(board)
    name = clean_name(name)
    note = " ".join(str(note).split())[:MAX_NOTE]
    seconds = max(60, min(int(seconds), MAX_CLAIM_S))
    now = time.time()
    with state_lock():
        claims = _live_claims(_load("claims.json"), now)
        cur = claims.get(board)
        if cur and not same_person(cur["name"], name):
            raise ClaimError(f"{board} is claimed by {cur['name']} until {_hm(cur['until'])}")
        new = {
            "name": cur["name"] if cur else name, "note": note or (cur or {}).get("note", ""),
            "since": cur["since"] if cur else now, "until": now + seconds,
        }
        claims[board] = new
        _save("claims.json", claims)
        _append_event({"t": now, "board": board, "user": name,
                       "kind": "extend" if cur else "claim",
                       "until": new["until"], "note": new["note"]})
    return new


def release(board: str, name: str, force: bool = False) -> None:
    _check_board(board)
    name = clean_name(name)
    now = time.time()
    with state_lock():
        claims = _live_claims(_load("claims.json"), now)
        cur = claims.get(board)
        if not cur:
            raise ClaimError(f"{board} is not claimed")
        if not same_person(cur["name"], name) and not force:
            raise ClaimError(f"{board} is claimed by {cur['name']}, not {name} (force to override)")
        del claims[board]
        _save("claims.json", claims)
        _append_event({"t": now, "board": board, "user": name,
                       "kind": "force-release" if not same_person(cur["name"], name) else "release",
                       "holder": cur["name"]})


def check(board: str, name: str) -> str | None:
    """None if `name` may use `board`, else the reason it may not"""
    cur = active_claims().get(board)
    if cur and not same_person(cur["name"], name):
        return f"{board} is claimed by {cur['name']} until {_hm(cur['until'])}"
    return None


def _bool(v) -> bool | None:
    """ectf.sh passes the tool's 'True'/'False' text"""
    return {"true": True, "false": False}.get(str(v).strip().lower())


def event(board: str, name: str, kind: str, fields: dict) -> None:
    """Record something ectf.sh did; flash/status also update boards.json"""
    now = time.time()
    with state_lock():
        info = _load("boards.json")
        b = info.setdefault(board, {})
        if kind == "status" and "version" in fields:
            b["bootloader"] = {"version": fields["version"], "secure": _bool(fields.get("secure")),
                               "design": fields.get("design") or None, "at": now}
        if kind == "flash":
            b["last_flash"] = {"user": name, "at": now} | {
                k: fields[k] for k in ("size", "image", "result") if k in fields}
            if "version" in fields:
                b["bootloader"] = {"version": fields["version"], "secure": _bool(fields.get("secure")),
                                   "design": fields.get("design") if fields.get("result") == "ok" else None,
                                   "at": now}
        _save("boards.json", info)
        _append_event({"t": now, "board": board, "user": name, "kind": kind} | fields)


def activity(board: str) -> dict | None:
    """What ectf.sh is doing on `board` right now, if anything"""
    try:
        user, action, since, pid = Path(f"/tmp/ectf-{board}.owner").read_text().rstrip("\n").split("\t")
    except (FileNotFoundError, ValueError):
        return None
    if not Path(f"/proc/{pid}").exists():
        return None  # stale (killed without cleanup)
    return {"user": user, "action": action, "since": float(since)}


def status() -> dict:
    now = time.time()
    claims = active_claims(now)
    info = _load("boards.json")
    boards = []
    for b in read_boards():
        boards.append(b | {
            "port_present": Path(b["port"]).exists(),
            "claim": claims.get(b["name"]),
            "activity": activity(b["name"]),
            "bootloader": info.get(b["name"], {}).get("bootloader"),
            "last_flash": info.get(b["name"], {}).get("last_flash"),
        })
    return {"now": now, "boards": boards, "events": recent_events()}


# ─── CLI ────────────────────────────────────────────────────────────


def _hm(t: float) -> str:
    return time.strftime("%H:%M", time.localtime(t))


def _ago(t: float, now: float) -> str:
    s = int(now - t)
    return f"{s}s" if s < 60 else f"{s // 60}m" if s < 3600 else f"{s // 3600}h{s % 3600 // 60:02d}m"


def print_status(st: dict) -> None:
    now = st["now"]
    print(f"{'BOARD':<8} {'CLAIM':<30} {'ACTIVITY':<26} {'BOOTLOADER':<18} {'GDB':<5} PORT")
    for b in st["boards"]:
        c, a, bl = b["claim"], b["activity"], b["bootloader"]
        claim_s = f"{c['name']} until {_hm(c['until'])}" if c else "-"
        if c and c.get("note"):
            claim_s += f" ({c['note']})"
        act_s = f"{a['action']} by {a['user']} {_ago(a['since'], now)}" if a else "idle"
        bl_s = (f"{bl['version']} {'SECURE' if bl.get('secure') else 'insecure'}" if bl else "?")
        port_s = b["port"] if b["port_present"] else f"{b['port']} (MISSING)"
        print(f"{b['name']:<8} {claim_s[:30]:<30} {act_s[:26]:<26} {bl_s:<18} {b['gdb_port'] or '-':<5} {port_s}")


def _kv(pairs: list[str]) -> dict:
    out = {}
    for p in pairs:
        k, _, v = p.partition("=")
        out[k] = v
    return out


def main_cli(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="boardctl.py", description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("status"); s.add_argument("--json", action="store_true")
    s = sub.add_parser("claim"); s.add_argument("board"); s.add_argument("name")
    s.add_argument("--for", dest="dur", default="2h"); s.add_argument("--note", default="")
    s = sub.add_parser("release"); s.add_argument("board"); s.add_argument("name")
    s.add_argument("--force", action="store_true")
    s = sub.add_parser("check"); s.add_argument("board"); s.add_argument("name")
    s = sub.add_parser("event"); s.add_argument("board"); s.add_argument("name")
    s.add_argument("kind"); s.add_argument("fields", nargs="*")
    s = sub.add_parser("serve"); s.add_argument("--host", default="0.0.0.0")
    s.add_argument("--port", type=int, default=8080)
    a = ap.parse_args(argv)

    try:
        match a.cmd:
            case "status":
                st = status()
                print(json.dumps(st, indent=1)) if a.json else print_status(st)
            case "claim":
                c = claim(a.board, a.name, parse_duration(a.dur), a.note)
                print(f"{a.board} claimed by {c['name']} until {_hm(c['until'])}")
            case "release":
                release(a.board, a.name, a.force)
                print(f"{a.board} released")
            case "check":
                if reason := check(a.board, a.name):
                    print(reason)
                    return 3
            case "event":
                event(a.board, a.name, a.kind, _kv(a.fields))
            case "serve":
                serve(a.host, a.port)
    except ClaimError as e:
        print(f"error: {e}", file=sys.stderr)
        return 3
    return 0


# ─── web ────────────────────────────────────────────────────────────


class Handler(BaseHTTPRequestHandler):
    server_version = "boardctl/1"

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, obj) -> None:
        self._send(code, json.dumps(obj).encode(), "application/json")

    def do_GET(self) -> None:
        if self.path in ("/", "/index.html"):
            self._send(200, DASHBOARD_HTML.read_bytes(), "text/html; charset=utf-8")
        elif self.path == "/api/status":
            self._json(200, status())
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        try:
            n = int(self.headers.get("Content-Length", 0))
            if n > 4096:
                raise ClaimError("request too large")
            req = json.loads(self.rfile.read(n) or b"{}")
            if self.path == "/api/claim":
                secs = parse_duration(req.get("duration", "2h"))
                c = claim(req.get("board", ""), req.get("name", ""), secs, req.get("note", ""))
                self._json(200, {"ok": True, "claim": c})
            elif self.path == "/api/release":
                release(req.get("board", ""), req.get("name", ""), bool(req.get("force")))
                self._json(200, {"ok": True})
            else:
                self._json(404, {"error": "not found"})
        except ClaimError as e:
            self._json(HTTPStatus.CONFLICT, {"error": str(e)})
        except (ValueError, json.JSONDecodeError) as e:
            self._json(HTTPStatus.BAD_REQUEST, {"error": f"bad request: {e}"})

    def log_message(self, fmt: str, *args) -> None:
        if not self.path.startswith("/api/status"):  # don't log the 3 s polling
            sys.stderr.write(f"{self.address_string()} {fmt % args}\n")


def serve(host: str, port: int) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    httpd = ThreadingHTTPServer((host, port), Handler)
    print(f"dashboard on http://{host}:{port}/", file=sys.stderr)
    httpd.serve_forever()


if __name__ == "__main__":
    sys.exit(main_cli(sys.argv[1:]))
