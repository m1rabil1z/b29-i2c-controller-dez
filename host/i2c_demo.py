# i2c_demo.py - store data in Board M, write it to a slave, read it back, verify, log to CSV
#    python i2c_demo.py --port COM5            (real board)
#    python i2c_demo.py --fake                 (no hardware, uses fake_board.py)
import argparse, csv, hashlib, os, random, time
from protocol import *

LOG_FIELDS = ["time", "test", "slave", "speed_idx", "n_bytes", "sent", "received",
              "status", "hw_verify", "py_verify", "ms"]

class Board:
    def __init__(self, ser, log):
        self.ser, self.log = ser, log

    def cmd(self, cmd, dev=0, data=b"", wait=2.0):
        self.ser.timeout = wait
        self.ser.reset_input_buffer()
        self.ser.write(build_request(cmd, dev, 0x00, data))
        return read_reply(self.ser)

    def round_trip(self, test, slave, data, speed_idx, wait=60.0):
        """clear, store, write to slave, read back, verify. One CSV row."""
        t0 = time.time()
        st, _ = self.cmd(CLEAR)
        st, _ = self.cmd(STORE, 0, data)
        if st == 0x00:
            st, _ = self.cmd(SEND_STORED, slave, wait=wait)        # waits until SW15 is ON
        back = b""
        if st == 0x00:
            st, back = self.cmd(READ_VERIFY, slave, wait=wait)
        ok_py = (back == data)
        self.log.writerow({"time": time.strftime("%H:%M:%S"), "test": test, "slave": hex(slave),
                           "speed_idx": speed_idx, "n_bytes": len(data), "sent": data.hex(),
                           "received": back.hex(), "status": STATUS.get(st, hex(st)),
                           "hw_verify": st == 0x00, "py_verify": ok_py,
                           "ms": round((time.time() - t0) * 1000, 1)})
        return st, back

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM5")
    ap.add_argument("--fake", action="store_true")
    ap.add_argument("--speed", type=int, default=4, help="SW2-0 setting on Board M, for the log")
    ap.add_argument("--file", help="file to send through the bus in 32-byte blocks")
    ap.add_argument("--rounds", type=int, default=20)
    a = ap.parse_args()

    if a.fake:
        from fake_board import FakeBoard
        ser = FakeBoard()
    else:
        import serial
        ser = serial.Serial(a.port, 115200, timeout=2)

    name = f"log_speed{a.speed}_{time.strftime('%Y%m%d_%H%M%S')}.csv"
    with open(name, "w", newline="") as f:
        log = csv.DictWriter(f, fieldnames=LOG_FIELDS)
        log.writeheader()
        b = Board(ser, log)

        # 1. link test, no I2C
        msg = bytes(random.randrange(256) for _ in range(16))
        st, back = b.cmd(ECHO, data=msg)
        print("ECHO:", "PASS" if st == 0 and back == msg else "FAIL")

        # 2. random data to both slaves
        fails = 0
        for i in range(a.rounds):
            for slave in (0x50, 0x51):
                data = bytes(random.randrange(256) for _ in range(random.randint(1, 32)))
                st, back = b.round_trip("random", slave, data, a.speed)
                fails += (st != 0x00 or back != data)
        print(f"random: {2 * a.rounds - fails}/{2 * a.rounds} PASS")

        # 3. error cases that must be reported, not hidden
        st, _ = b.cmd(SEND_STORED, 0x42)
        print("wrong address 0x42 ->", STATUS.get(st))
        b.cmd(CLEAR)
        st, _ = b.cmd(READ_VERIFY, 0x50)
        print("read with nothing stored ->", STATUS.get(st))
        bad = bytearray(build_request(ECHO, data=b"\x11\x22")); bad[-1] ^= 0xFF
        ser.write(bytes(bad)); st, _ = read_reply(ser)
        print("corrupted packet ->", STATUS.get(st))

        # 4. file transfer in 32-byte blocks
        if a.file:
            src = open(a.file, "rb").read()
            got = bytearray()
            for k in range(0, len(src), 32):
                st, back = b.round_trip("file", 0x50, src[k:k + 32], a.speed)
                got += back
            same = hashlib.sha256(src).hexdigest() == hashlib.sha256(bytes(got)).hexdigest()
            print(f"file {os.path.basename(a.file)}: {len(src)} bytes,", "PASS" if same else "FAIL")

    print("log written to", name)
    ser.close()

if __name__ == "__main__":
    main()