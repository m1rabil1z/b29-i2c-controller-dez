# protocol.py - the packet format between the laptop and Board M
#
#   request (laptop -> Board M):  A5 | CMD | DEV | REG | LEN | DATA x LEN | CRC
#   reply   (Board M -> laptop):  5A | STATUS | LEN | DATA x LEN | CRC
#   CRC-8: poly 0x07, init 0x00, over every byte after the sync byte.
import time

SYNC_REQ, SYNC_REP = 0xA5, 0x5A
MAX_STORE = 32                     # bytes Board M can hold

# commands
ECHO, STORE, SEND_STORED, CLEAR, READ_VERIFY = 0x04, 0x05, 0x06, 0x07, 0x09
CMD_NAME = {ECHO: "ECHO", STORE: "STORE", SEND_STORED: "SEND_STORED",
            CLEAR: "CLEAR", READ_VERIFY: "READ_VERIFY"}

# status codes sent by Board M
OK, BAD_CRC, NACK, UNKNOWN_CMD, TIMEOUT = 0x00, 0x01, 0x02, 0x04, 0x05
STORE_FULL, MISMATCH, NOTHING_STORED = 0x07, 0x08, 0x09
# results the script itself can see (never sent by the board)
NO_REPLY, BAD_REPLY = -1, -2

STATUS = {OK: "OK", BAD_CRC: "BAD_CRC", NACK: "NACK", UNKNOWN_CMD: "UNKNOWN_CMD",
          TIMEOUT: "TIMEOUT", STORE_FULL: "STORE_FULL", MISMATCH: "MISMATCH",
          NOTHING_STORED: "NOTHING_STORED", NO_REPLY: "NO_REPLY", BAD_REPLY: "BAD_REPLY"}


def status_name(code):
    return STATUS.get(code, f"0x{code:02X}")


def crc8(data: bytes) -> int:
    """CRC-8, poly 0x07, init 0x00. crc8(b'123456789') == 0xF4."""
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def build_request(cmd: int, dev: int = 0, reg: int = 0, data: bytes = b"") -> bytes:
    body = bytes([cmd, dev, reg, len(data)]) + bytes(data)
    return bytes([SYNC_REQ]) + body + bytes([crc8(body)])


class NoReply(Exception):
    pass


class BadReply(Exception):
    pass


def _read_exact(ser, n, deadline, on_wait=None, wait_every=3.0):
    """Read n bytes before the deadline. Calls on_wait(seconds) now and then while waiting."""
    out = bytearray()
    last_note = time.monotonic()
    while len(out) < n:
        if time.monotonic() > deadline:
            raise NoReply(f"got {len(out)} of {n} bytes")
        chunk = ser.read(n - len(out))
        if chunk:
            out += chunk
        elif on_wait and time.monotonic() - last_note >= wait_every:
            last_note = time.monotonic()
            on_wait(deadline - time.monotonic())
    return bytes(out)


def read_reply(ser, timeout, on_wait=None):
    """Wait for 5A, then STATUS LEN DATA CRC. Returns (status, data, raw_reply_bytes)."""
    deadline = time.monotonic() + timeout
    while True:                                   # skip anything before the sync byte
        b = _read_exact(ser, 1, deadline, on_wait)
        if b[0] == SYNC_REP:
            break
    status, n = _read_exact(ser, 2, deadline, on_wait)
    rest = _read_exact(ser, n + 1, deadline, on_wait)
    data, crc = rest[:n], rest[n]
    raw = bytes([SYNC_REP, status, n]) + rest
    if crc8(bytes([status, n]) + data) != crc:
        raise BadReply(f"reply CRC wrong: {raw.hex(' ')}")
    return status, data, raw
