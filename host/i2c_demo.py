# i2c_demo.py - laptop side of the I2C project (Board M over USB-UART)
#
# Two modes:
#   manual  type commands, watch the boards react. For the live demo.
#   auto    runs the full test plan by itself and writes a CSV log + report.
#
# Examples:
#   python i2c_demo.py manual --port COM5
#   python i2c_demo.py auto   --port COM5 --speed 4 --rounds 20 --file test.bin
#   python i2c_demo.py auto   --port COM5 --ladder 1-7            (asks you to change SW2-0)
#   python i2c_demo.py auto   --fake --fault-rate 0.05            (no hardware)
import argparse, hashlib, os, random, shlex, sys, time
from protocol import *
from link import Link
from report import RunLog, SPEED_NAME, bus_ms_estimate

# where each slave's last byte shows up on Board S
SLAVE_SHOWS = {0x50: "LD15-8 and digits 3-2", 0x51: "LD7-0 and digits 1-0"}


# ======================================================================
#  shared helpers
# ======================================================================
def open_port(args):
    if args.fake:
        from fake_board import FakeBoard
        return FakeBoard(slaves=args.slaves, fault_rate=args.fault_rate, seed=args.seed)
    import serial
    return serial.Serial(args.port, args.baud, timeout=0.2)


def fmt(data: bytes) -> str:
    """hex plus printable ASCII, e.g.  48 49 21  'HI!'"""
    if not data:
        return "(none)"
    text = "".join(chr(b) if 32 <= b < 127 else "." for b in data)
    return f"{data.hex(' ').upper()}  '{text}'"


def transfer_timeout(n_bytes, speed_idx):
    """Generous wait for one write or read: 3x the bus time + 5 s for the UART and margin."""
    return 3 * bus_ms_estimate(n_bytes, speed_idx) / 1000 + 5


def round_trip(link, slave, data, timeout, on_wait=None, pause=None):
    """clear -> store -> write -> (pause) -> read back. Returns a dict with every result."""
    t0 = time.perf_counter()
    r = {"stage": "", "status": OK, "got": b"", "hw": False, "py": False, "mism": len(data)}
    c = link.clear()
    if c.status != OK:
        r.update(stage="clear", status=c.status)
    else:
        s = link.store(data)
        if s.status != OK:
            r.update(stage="store", status=s.status)
        else:
            w = link.send_stored(slave, timeout=timeout, on_wait=on_wait)
            if w.status != OK:
                r.update(stage="write", status=w.status)
            else:
                if pause:
                    pause()
                rd = link.read_verify(slave, timeout=timeout, on_wait=on_wait)
                mism = sum(a != b for a, b in zip(rd.data, data)) + abs(len(rd.data) - len(data))
                r.update(stage="read", status=rd.status, got=rd.data, hw=(rd.status == OK),
                         py=(rd.data == bytes(data)), mism=mism)
    r["ms"] = (time.perf_counter() - t0) * 1000
    return r


# ======================================================================
#  MANUAL MODE
# ======================================================================
HELP = """
commands (bytes can be hex like 11 22 0x33, or text in quotes like "HELLO"):
  store <bytes>          add bytes to Board M's buffer (up to 32 in total)
  clear                  empty Board M's buffer
  write <slave>          write the stored bytes to slave 50 or 51 (waits for SW15 ON)
  read <slave>           read them back from the slave and verify
  rt <slave> <bytes>     round trip: clear, store, write, pause for you to look, read back
  echo <bytes>           link test, no I2C
  raw <hex bytes>        send exact bytes (e.g. a packet with a wrong CRC)
  show                   what the laptop thinks is stored
  help | quit
"""


def parse_bytes(tokens):
    out = bytearray()
    for t in tokens:
        if t.lower().startswith("0x"):
            t = t[2:]
        if all(c in "0123456789abcdefABCDEF" for c in t) and len(t) in (1, 2):
            out.append(int(t, 16))
        else:
            out += t.encode("ascii")           # quoted text (shlex already removed the quotes)
    return bytes(out)


def parse_slave(tok):
    v = int(tok, 16)
    if not 0 < v < 0x80:
        raise ValueError("slave address must be 7-bit hex, e.g. 50")
    return v


def run_manual(args):
    ser = open_port(args)
    log = RunLog(args.out, {"mode": "manual", "port": "fake" if args.fake else args.port}) if args.log else None
    link = Link(ser, on_exchange=log.exchange if log else None)
    stored = bytearray()                       # the laptop's copy of Board M's buffer

    def waiting(left):
        print(f"    ...waiting for Board M ({left:.0f} s left). Is SW15 ON? Slow speed? Ctrl+C stops waiting.")

    def show(ex):
        print(f"  -> {ex.status_name}   ({ex.ms:.1f} ms)   reply: {ex.reply.hex(' ').upper() or '(none)'}")
        return ex

    print("Manual mode. Type 'help' for commands.")
    while True:
        try:
            line = input("i2c> ").strip()
        except EOFError:
            break
        if not line:
            continue
        try:
            parts = shlex.split(line)
            cmd, rest = parts[0].lower(), parts[1:]
            tmo = args.wait
            if cmd in ("quit", "exit", "q"):
                break
            elif cmd == "help":
                print(HELP)
            elif cmd == "show":
                print(f"  stored ({len(stored)} bytes): {fmt(bytes(stored))}")
            elif cmd == "clear":
                if show(link.clear()).status == OK:
                    stored.clear()
            elif cmd == "store":
                data = parse_bytes(rest)
                if not data:
                    print("  nothing to store"); continue
                ex = show(link.store(data))
                if ex.status == OK:
                    stored += data
                    print(f"  stored now ({len(stored)} bytes): {fmt(bytes(stored))}")
                    print(f"  Board M: LD7-0 = {data[-1]:02X}, digits 3-2 = {len(stored):02X}")
            elif cmd == "write":
                slave = parse_slave(rest[0])
                print(f"  writing {len(stored)} bytes to 0x{slave:02X} (needs Board M SW15 ON)...")
                ex = show(link.send_stored(slave, timeout=tmo, on_wait=waiting))
                if ex.status == OK and stored:
                    print(f"  Board S: {SLAVE_SHOWS.get(slave, 'its LEDs')} should now show {stored[-1]:02X}")
            elif cmd == "read":
                slave = parse_slave(rest[0])
                ex = show(link.read_verify(slave, timeout=tmo, on_wait=waiting))
                print(f"  read back: {fmt(ex.data)}")
                if ex.data:
                    same = ex.data == bytes(stored)
                    print(f"  Board M check: {ex.status_name}   laptop check: {'MATCH' if same else 'DIFFERENT'}")
                    print(f"  Board M: LD8 = verify OK, LD9 = verify bad; LD7-0 = {ex.data[-1]:02X}")
            elif cmd == "rt":
                slave, data = parse_slave(rest[0]), parse_bytes(rest[1:])
                if not 0 < len(data) <= MAX_STORE:
                    print(f"  need 1 to {MAX_STORE} bytes"); continue
                pause = lambda: input(f"  written. Board S {SLAVE_SHOWS.get(slave, '')} shows "
                                      f"{data[-1]:02X}. Press Enter to read it back... ")
                r = round_trip(link, slave, data, tmo, on_wait=waiting, pause=pause)
                stored[:] = data
                print(f"  sent:      {fmt(data)}")
                print(f"  read back: {fmt(r['got'])}")
                print(f"  result: {status_name(r['status'])} at '{r['stage']}'   "
                      f"Board M verify: {'OK' if r['hw'] else 'FAIL'}   laptop verify: {'OK' if r['py'] else 'FAIL'}"
                      f"   ({r['ms']:.0f} ms)")
            elif cmd == "echo":
                data = parse_bytes(rest)
                ex = show(link.echo(data))
                print(f"  echoed: {fmt(ex.data)}   {'MATCH' if ex.data == data else 'DIFFERENT'}")
            elif cmd == "raw":
                ex = show(link.exchange(0, raw=bytes(parse_bytes(rest)), name="RAW", timeout=2.0))
                print(f"  reply data: {fmt(ex.data)}")
            else:
                print("  unknown command, type 'help'")
        except KeyboardInterrupt:
            print("\n  stopped waiting. Board M may still finish that transfer; its reply will be dropped.")
            link.resync()
        except (ValueError, IndexError) as e:
            print(f"  error: {e}")
    if log:
        print("log written to", log.close())
    ser.close()


# ======================================================================
#  AUTOMATIC MODE
# ======================================================================
class Operator:
    """Asks the person at the boards to do something. With the fake board it does it itself."""
    def __init__(self, fake_board=None, prompts=True):
        self.fake, self.prompts = fake_board, prompts

    def ask(self, text):
        if self.fake is not None:
            print(f"  [fake] {text}")
        else:
            input(f"\n  >>> {text}  [press Enter] ")

    def switch(self, board, sw, on, what):
        if self.fake is not None:
            f = self.fake
            if (board, sw) == ("M", "SW15"): f.protocol_on = on
            if (board, sw) == ("S", "SW15"): f.force_nack[0x50] = on
            if (board, sw) == ("S", "SW14"): f.force_nack[0x51] = on
            if (board, sw) == ("S", "SW13"): f.invert = on
        self.ask(f"Board {board}: set {sw} {'ON (up)' if on else 'OFF (down)'}  ({what})")


PATTERNS = ["random", "zeros", "ones", "alternating", "counting", "ascii"]


def make_data(pattern, n, rng):
    if pattern == "zeros":       return bytes(n)
    if pattern == "ones":        return bytes([0xFF] * n)
    if pattern == "alternating": return bytes([0xAA, 0x55] * n)[:n]
    if pattern == "counting":    return bytes(range(n))
    if pattern == "ascii":       return bytes(rng.choice(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ") for _ in range(n))
    return bytes(rng.randrange(256) for _ in range(n))


def suite_link(link, log, args, rng):
    print(f"\n== link: {args.echo_count} ECHO packets (UART only)")
    for i in range(args.echo_count):
        data = make_data("random", rng.randint(1, MAX_STORE), rng)
        log.test_id = f"ECHO-{i + 1:03d}"
        ex = link.echo(data)
        ok = ex.status == OK and ex.data == data
        log.test(test_id=log.test_id, suite="link", n_bytes=len(data), pattern="random",
                 expected="OK + same data", got=ex.status_name, py_verify=ex.data == data, ms=ex.ms,
                 result="PASS" if ok else "FAIL", note=f"{len(data)} bytes")


def suite_roundtrip(link, log, args, rng, sp):
    cap = min(args.max_bytes, {0: 2, 1: 16}.get(sp, MAX_STORE))
    n_total = args.rounds * len(args.slaves)
    print(f"\n== roundtrip at {SPEED_NAME[sp]}: {n_total} round trips, 1-{cap} bytes each")
    k = 0
    for i in range(args.rounds):
        for slave in args.slaves:
            k += 1
            pat = PATTERNS[k % len(PATTERNS)]
            data = make_data(pat, rng.randint(1, cap), rng)
            log.test_id = f"RT{sp}-{k:03d}"
            r = round_trip(link, slave, data, transfer_timeout(len(data), sp))
            ok = r["hw"] and r["py"]
            log.test(test_id=log.test_id, suite="roundtrip", speed_idx=sp, slave=f"0x{slave:02X}",
                     n_bytes=len(data), pattern=pat, expected="OK, identical", got=status_name(r["status"]),
                     hw_verify=r["hw"], py_verify=r["py"], mismatches=r["mism"], ms=r["ms"],
                     result="PASS" if ok else "FAIL",
                     note=f"{pat}, {len(data)} B" + ("" if ok else f", failed at {r['stage']}"))


def suite_errors(link, log, args, sp):
    print("\n== errors: every fault must be reported, not hidden")
    slave = args.slaves[0]

    def case(tid, desc, expected, ex, extra_ok=True):
        log.test(test_id=tid, suite="errors", speed_idx=sp, expected=status_name(expected),
                 got=ex.status_name, ms=ex.ms, result="PASS" if ex.status == expected and extra_ok else "FAIL",
                 note=desc)

    log.test_id = "ERR-NACK"
    link.clear(); link.store(b"\x5A")
    case("ERR-NACK", f"write to absent slave 0x{args.absent:02X}", NACK,
         link.send_stored(args.absent, timeout=transfer_timeout(1, sp)))

    log.test_id = "ERR-EMPTY"
    link.clear()
    case("ERR-EMPTY", "read-back with nothing stored", NOTHING_STORED,
         link.read_verify(slave, timeout=transfer_timeout(1, sp)))

    log.test_id = "ERR-CRC"
    bad = bytearray(build_request(ECHO, data=b"\x11\x22")); bad[-1] ^= 0xFF
    case("ERR-CRC", "request with a corrupted CRC byte", BAD_CRC, link.exchange(0, raw=bytes(bad), name="ECHO(bad CRC)"))

    log.test_id = "ERR-FULL"
    link.clear(); link.store(bytes(MAX_STORE))
    case("ERR-FULL", f"store byte {MAX_STORE + 1}", STORE_FULL, link.store(b"\x01"))

    log.test_id = "ERR-UNKNOWN"
    case("ERR-UNKNOWN", "unknown command 0x0F", UNKNOWN_CMD, link.exchange(0x0F))

    log.test_id = "ERR-CUTOFF"
    part = build_request(ECHO, data=b"\x01\x02\x03")[:4]
    case("ERR-CUTOFF", "packet cut off after 4 bytes (10 ms timeout)", TIMEOUT,
         link.exchange(0, raw=part, name="ECHO(cut off)", timeout=1.0))

    log.test_id = "ERR-RECOVER"
    ex = link.echo(b"\xC3")
    case("ERR-RECOVER", "next good packet after the cut-off one", OK, ex, ex.data == b"\xC3")
    link.clear()


def suite_guided(link, log, args, op, sp):
    print("\n== guided: tests that need a switch flipped")
    s0 = args.slaves[0]
    s1 = args.slaves[-1]
    tmo = transfer_timeout(8, sp)

    # 1. protocol OFF holds the transfer, ON releases it
    log.test_id = "G-HOLD"
    link.clear(); link.store(b"HOLD")
    op.switch("M", "SW15", False, "protocol OFF")
    req = build_request(SEND_STORED, s0)
    link.ser.reset_input_buffer(); link.ser.write(req)
    t0 = time.perf_counter()
    try:
        read_reply(link.ser, 2.0); held = False
    except NoReply:
        held = True
    op.switch("M", "SW15", True, "protocol ON")
    try:
        st, _, _ = read_reply(link.ser, tmo + 30)
    except (NoReply, BadReply):
        st = NO_REPLY
    log.test(test_id="G-HOLD", suite="guided", speed_idx=sp, slave=f"0x{s0:02X}", n_bytes=4,
             expected="no reply while OFF, then OK", got=("held, " if held else "NOT held, ") + status_name(st),
             ms=(time.perf_counter() - t0) * 1000, result="PASS" if held and st == OK else "FAIL",
             note="Board M SW15 gates the protocol")

    # 2. Board S forces NACK on the first slave
    log.test_id = "G-FORCE-NACK"
    sw = "SW15" if s0 == 0x50 else "SW14"
    op.switch("S", sw, True, f"force NACK on 0x{s0:02X}")
    link.clear(); link.store(b"\x42")
    ex = link.send_stored(s0, timeout=tmo)
    op.switch("S", sw, False, "back to normal")
    log.test(test_id="G-FORCE-NACK", suite="guided", speed_idx=sp, slave=f"0x{s0:02X}", expected="NACK",
             got=ex.status_name, ms=ex.ms, result="PASS" if ex.status == NACK else "FAIL",
             note=f"Board S {sw} refuses the address")

    # 3. Board S inverts reads: Board M must catch every byte
    log.test_id = "G-INVERT"
    data = bytes([0x12, 0x34, 0x56, 0x78])
    op.switch("S", "SW13", True, "invert reads")
    r = round_trip(link, s1, data, tmo)
    op.switch("S", "SW13", False, "back to normal")
    inv_ok = r["status"] == MISMATCH and r["got"] == bytes(b ^ 0xFF for b in data)
    log.test(test_id="G-INVERT", suite="guided", speed_idx=sp, slave=f"0x{s1:02X}", n_bytes=4,
             expected="MISMATCH, 4 bytes inverted", got=f"{status_name(r['status'])}, {r['mism']} wrong",
             hw_verify=r["hw"], py_verify=r["py"], mismatches=r["mism"], ms=r["ms"],
             result="PASS" if inv_ok else "FAIL", note="corruption is detected, not hidden")


def suite_file(link, log, args, sp):
    src = open(args.file, "rb").read()
    slave = args.file_slave
    n_chunks = (len(src) + MAX_STORE - 1) // MAX_STORE
    print(f"\n== file: {os.path.basename(args.file)}, {len(src)} bytes in {n_chunks} blocks to 0x{slave:02X}")
    got, t0, bad = bytearray(), time.perf_counter(), 0
    for i in range(n_chunks):
        chunk = src[i * MAX_STORE:(i + 1) * MAX_STORE]
        log.test_id = f"FILE-{i + 1:04d}"
        r = round_trip(link, slave, chunk, transfer_timeout(len(chunk), sp))
        got += r["got"]
        ok = r["hw"] and r["py"]
        bad += not ok
        log.test(test_id=log.test_id, suite="file", speed_idx=sp, slave=f"0x{slave:02X}", n_bytes=len(chunk),
                 pattern="file", expected="OK, identical", got=status_name(r["status"]), hw_verify=r["hw"],
                 py_verify=r["py"], mismatches=r["mism"], ms=r["ms"], result="PASS" if ok else "FAIL",
                 note=f"block {i + 1}/{n_chunks}")
    secs = time.perf_counter() - t0
    h_src, h_got = hashlib.sha256(src).hexdigest(), hashlib.sha256(bytes(got)).hexdigest()
    same = h_src == h_got
    log.test(test_id="FILE", suite="file", speed_idx=sp, slave=f"0x{slave:02X}", n_bytes=len(src),
             pattern=os.path.basename(args.file), expected=f"sha256 {h_src[:16]}", got=f"sha256 {h_got[:16]}",
             ms=secs * 1000, result="PASS" if same else "FAIL",
             note=f"{n_chunks} blocks, {bad} failed, {len(src) / secs:.0f} B/s end to end")


def run_auto(args):
    ser = open_port(args)
    meta = {"mode": "auto", "port": "fake board" if args.fake else args.port, "baud": args.baud,
            "slaves": ", ".join(f"0x{s:02X}" for s in args.slaves), "rounds per speed": args.rounds,
            "speeds": ", ".join(SPEED_NAME[s] for s in args.speeds), "suites": ", ".join(args.suites),
            "seed": args.seed}
    if args.fake:
        meta["fault rate (fake)"] = args.fault_rate
    log = RunLog(args.out, meta)
    link = Link(ser, on_exchange=log.exchange)
    op = Operator(ser if args.fake else None, prompts=not args.no_prompts)
    rng = random.Random(args.seed)
    print(f"Automatic mode. Logging to {log.dir}")

    if "link" in args.suites:
        suite_link(link, log, args, rng)
    for i, sp in enumerate(args.speeds):
        if len(args.speeds) > 1 and not args.no_prompts:
            op.ask(f"Board M: set SW2-0 to {sp} ({SPEED_NAME[sp]}), SW15 ON")
        if "roundtrip" in args.suites:
            suite_roundtrip(link, log, args, rng, sp)
    sp = args.speeds[-1]
    if "errors" in args.suites:
        suite_errors(link, log, args, sp)
    if "guided" in args.suites:
        if args.no_prompts and not args.fake:
            print("\n== guided: skipped (--no-prompts)")
        else:
            suite_guided(link, log, args, op, sp)
    if "file" in args.suites and args.file:
        suite_file(link, log, args, sp)

    out = log.close()
    n_pass = sum(r["result"] == "PASS" for r in log.tests)
    print(f"\n{n_pass} of {len(log.tests)} tests passed. Report: {os.path.join(out, 'report.md')}")
    ser.close()
    return n_pass == len(log.tests)


# ======================================================================
def parse_speeds(text):
    out = []
    for part in text.split(","):
        a, _, b = part.partition("-")
        out += range(int(a), int(b or a) + 1)
    if any(not 0 <= s <= 7 for s in out):
        raise argparse.ArgumentTypeError("speed index must be 0-7")
    return out


def main():
    ap = argparse.ArgumentParser(description="I2C project: laptop side")
    ap.add_argument("mode", choices=["manual", "auto"])
    ap.add_argument("--port", default="COM5", help="Board M's COM port")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--fake", action="store_true", help="no hardware: use the fake board")
    ap.add_argument("--fault-rate", type=float, default=0.0, help="fake board only: random bus faults")
    ap.add_argument("--slaves", default="50,51", help="slave addresses in hex")
    ap.add_argument("--absent", default="42", help="an address with no slave, for the NACK test")
    ap.add_argument("--out", default="logs", help="folder for the run folders")
    ap.add_argument("--seed", type=int, default=1)
    # manual
    ap.add_argument("--wait", type=float, default=120, help="manual: seconds to wait for a transfer")
    ap.add_argument("--log", action="store_true", help="manual: also log every packet to CSV")
    # auto
    ap.add_argument("--speed", type=int, default=4, help="auto: Board M SW2-0 setting (0-7)")
    ap.add_argument("--ladder", type=parse_speeds, help="auto: several speeds, e.g. 1-7; prompts you to change SW2-0")
    ap.add_argument("--rounds", type=int, default=20, help="auto: round trips per slave per speed")
    ap.add_argument("--max-bytes", type=int, default=MAX_STORE)
    ap.add_argument("--echo-count", type=int, default=50)
    ap.add_argument("--file", help="auto: file to send through the bus")
    ap.add_argument("--file-slave", default="50")
    ap.add_argument("--suites", default="link,roundtrip,errors,guided,file")
    ap.add_argument("--no-prompts", action="store_true", help="auto: unattended, skip switch-guided tests")
    args = ap.parse_args()

    args.slaves = [int(s, 16) for s in args.slaves.split(",")]
    args.absent = int(args.absent, 16)
    args.file_slave = int(args.file_slave, 16)
    args.suites = [s.strip() for s in args.suites.split(",")]
    args.speeds = args.ladder or [args.speed]
    args.max_bytes = max(1, min(args.max_bytes, MAX_STORE))

    if args.mode == "manual":
        run_manual(args)
    else:
        sys.exit(0 if run_auto(args) else 1)


if __name__ == "__main__":
    main()
