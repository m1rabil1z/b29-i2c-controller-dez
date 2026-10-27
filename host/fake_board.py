# fake_board.py - pretends to be Board M + Board S at the packet level.
# Lets both modes run with no hardware. It also simulates:
#   protocol_on       Board M SW15 (writes/reads wait while it's off)
#   force_nack[addr]  Board S SW15 / SW14
#   invert            Board S SW13
#   fault_rate        random bus errors (a corrupted byte in the slave, or a lost reply)
#   the 10 ms cut-off-packet timeout (status 0x05)
import random, time
from protocol import *


class FakeBoard:
    def __init__(self, slaves=(0x50, 0x51), fault_rate=0.0, seed=None):
        self.mem = {a: bytearray(240) for a in slaves}
        self.store = bytearray()
        self.protocol_on = True
        self.force_nack = {a: False for a in slaves}
        self.invert = False
        self.fault_rate = fault_rate
        self.rng = random.Random(seed)
        self.timeout = 1.0
        self.inbuf, self.out = bytearray(), bytearray()
        self.last_rx = time.monotonic()
        self.held = None                       # request waiting for protocol_on

    # ---- pyserial-like interface ----
    def reset_input_buffer(self):
        self.out = bytearray()

    def close(self):
        pass

    def write(self, data):
        self.inbuf += bytes(data)
        self.last_rx = time.monotonic()
        self._parse()

    def read(self, k):
        self._tick()
        if not self.out:
            time.sleep(min(self.timeout, 0.01))
            self._tick()
        r, self.out = bytes(self.out[:k]), self.out[k:]
        return r

    # ---- inside the fake board ----
    def _tick(self):
        if self.held and self.protocol_on:     # SW15 turned on: run the held request
            cmd, dev = self.held
            self.held = None
            self._run_transfer(cmd, dev)
        if self.inbuf and time.monotonic() - self.last_rx > 0.010:
            self.inbuf = bytearray()           # packet cut off
            self._reply(TIMEOUT)

    def _parse(self):
        while True:
            while self.inbuf and self.inbuf[0] != SYNC_REQ:
                self.inbuf.pop(0)
            if len(self.inbuf) < 6:
                return
            n = self.inbuf[4]
            if len(self.inbuf) < 6 + n:
                return
            pkt, self.inbuf = bytes(self.inbuf[:6 + n]), self.inbuf[6 + n:]
            self._handle(pkt)

    def _handle(self, pkt):
        cmd, dev, reg, n = pkt[1:5]
        data, crc = pkt[5:5 + n], pkt[5 + n]
        if crc8(pkt[1:5 + n]) != crc:
            return self._reply(BAD_CRC)
        if cmd == ECHO:
            return self._reply(OK, data) if n <= MAX_STORE else self._reply(STORE_FULL)
        if cmd == CLEAR:
            self.store = bytearray()
            return self._reply(OK)
        if cmd == STORE:
            if n == 0 or len(self.store) + n > MAX_STORE:
                return self._reply(STORE_FULL)
            self.store += data
            return self._reply(OK)
        if cmd in (SEND_STORED, READ_VERIFY):
            if self.protocol_on:
                return self._run_transfer(cmd, dev)
            self.held = (cmd, dev)             # no reply until SW15 is on
            return
        self._reply(UNKNOWN_CMD)

    def _run_transfer(self, cmd, dev):
        if dev not in self.mem or self.force_nack.get(dev):
            return self._reply(NACK)
        if self.rng.random() < self.fault_rate / 2:
            return                             # reply lost
        n = len(self.store)
        if cmd == SEND_STORED:
            self.mem[dev][0:n] = self.store
            if n and self.rng.random() < self.fault_rate:
                self.mem[dev][self.rng.randrange(n)] ^= 0x10   # bus error
            return self._reply(OK)
        if n == 0:
            return self._reply(NOTHING_STORED)
        back = bytes(self.mem[dev][0:n])
        if self.invert:
            back = bytes(b ^ 0xFF for b in back)
        self._reply(OK if back == bytes(self.store) else MISMATCH, back)

    def _reply(self, status, data=b""):
        body = bytes([status, len(data)]) + bytes(data)
        self.out += bytes([SYNC_REP]) + body + bytes([crc8(body)])
