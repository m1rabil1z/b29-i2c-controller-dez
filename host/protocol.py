# protocol.py - packets between the laptop and Board M (team guide section 5 + v2 commands)
SYNC_REQ, SYNC_REP = 0xA5, 0x5A

ECHO, STORE, SEND_STORED, CLEAR, READ_VERIFY = 0x04, 0x05, 0x06, 0x07, 0x09

STATUS = {0x00: "OK", 0x01: "BAD_CRC", 0x02: "NACK", 0x04: "UNKNOWN_CMD",
          0x05: "TIMEOUT", 0x07: "STORE_FULL", 0x08: "MISMATCH", 0x09: "NOTHING_STORED"}

def crc8(data: bytes) -> int:
    """CRC-8, poly 0x07, init 0x00. crc8(b'123456789') must be 0xF4."""
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c

def build_request(cmd: int, dev: int = 0, reg: int = 0, data: bytes = b"") -> bytes:
    body = bytes([cmd, dev, reg, len(data)]) + data
    return bytes([SYNC_REQ]) + body + bytes([crc8(body)])

def read_reply(ser) -> tuple:
    """Wait for 5A, then STATUS LEN DATA CRC. Returns (status, data). Raises on timeout or bad CRC."""
    while True:
        b = ser.read(1)
        if not b:
            raise TimeoutError("no reply from Board M")
        if b[0] == SYNC_REP:
            break
    head = ser.read(2)
    if len(head) < 2:
        raise TimeoutError("reply cut off")
    status, n = head
    rest = ser.read(n + 1)
    if len(rest) < n + 1:
        raise TimeoutError("reply cut off")
    data, crc = rest[:n], rest[n]
    if crc8(bytes([status, n]) + data) != crc:
        raise ValueError("bad CRC in reply")
    return status, data