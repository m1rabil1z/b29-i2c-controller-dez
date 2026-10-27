# link.py - one request, one reply, never crashes. Used by both modes.
import time
from dataclasses import dataclass
from protocol import *


@dataclass
class Exchange:
    cmd: str
    dev: int
    sent: bytes          # data bytes in the request
    request: bytes       # whole request packet
    status: int
    data: bytes          # data bytes in the reply
    reply: bytes         # whole reply packet ('' if none)
    ms: float            # request sent -> reply complete

    @property
    def status_name(self):
        return status_name(self.status)


class Link:
    def __init__(self, ser, on_exchange=None):
        self.ser = ser
        self.on_exchange = on_exchange      # callback, e.g. the logger

    def exchange(self, cmd, dev=0, data=b"", timeout=2.0, on_wait=None, raw=None, name=None):
        """Send one request (or 'raw' bytes) and wait for its reply."""
        req = raw if raw is not None else build_request(cmd, dev, 0x00, bytes(data))
        self.ser.reset_input_buffer()
        t0 = time.perf_counter()
        self.ser.write(req)
        try:
            status, rdata, rep = read_reply(self.ser, timeout, on_wait)
        except NoReply:
            status, rdata, rep = NO_REPLY, b"", b""
            self.resync()
        except BadReply:
            status, rdata, rep = BAD_REPLY, b"", b""
            self.resync()
        ex = Exchange(name or CMD_NAME.get(cmd, f"0x{cmd:02X}"), dev, bytes(data), req,
                      status, rdata, rep, (time.perf_counter() - t0) * 1000)
        if self.on_exchange:
            self.on_exchange(ex)
        return ex

    def resync(self):
        """After a lost reply: wait past Board M's 10 ms packet timeout, drop stale bytes."""
        time.sleep(0.05)
        self.ser.reset_input_buffer()

    # short names for the five commands
    def echo(self, data, **kw):        return self.exchange(ECHO, 0, data, **kw)
    def clear(self, **kw):             return self.exchange(CLEAR, **kw)
    def store(self, data, **kw):       return self.exchange(STORE, 0, data, **kw)
    def send_stored(self, dev, **kw):  return self.exchange(SEND_STORED, dev, **kw)
    def read_verify(self, dev, **kw):  return self.exchange(READ_VERIFY, dev, **kw)
