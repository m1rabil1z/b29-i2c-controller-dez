# fake_board.py - pretends to be Board M + Board S, so the script runs without hardware
from protocol import *

class FakeBoard:
    def __init__(self, slaves=(0x50, 0x51)):
        self.mem = {a: bytearray(240) for a in slaves}
        self.store, self.out, self.timeout = bytearray(), bytearray(), 1.0
    def reset_input_buffer(self): pass
    def close(self): pass
    def write(self, pkt):
        pkt = bytes(pkt)
        assert pkt[0] == SYNC_REQ
        cmd, dev, reg, n = pkt[1:5]
        data, crc = pkt[5:5 + n], pkt[5 + n]
        if crc8(pkt[1:5 + n]) != crc:
            return self._reply(0x01)
        if cmd == ECHO:
            return self._reply(0x00, data)
        if cmd == CLEAR:
            self.store = bytearray(); return self._reply(0x00)
        if cmd == STORE:
            if len(self.store) + n > 32: return self._reply(0x07)
            self.store += data; return self._reply(0x00)
        if cmd in (SEND_STORED, READ_VERIFY):
            if dev not in self.mem: return self._reply(0x02)
            if cmd == SEND_STORED:
                self.mem[dev][0:len(self.store)] = self.store; return self._reply(0x00)
            if not self.store: return self._reply(0x09)
            back = bytes(self.mem[dev][0:len(self.store)])
            return self._reply(0x00 if back == bytes(self.store) else 0x08, back)
        return self._reply(0x04)
    def _reply(self, status, data=b""):
        body = bytes([status, len(data)]) + bytes(data)
        self.out += bytes([SYNC_REP]) + body + bytes([crc8(body)])
    def read(self, k):
        r, self.out = bytes(self.out[:k]), self.out[k:]
        return r