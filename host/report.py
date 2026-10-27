# report.py - CSV logs and the summary report for automatic mode
#
# One folder per run, e.g. logs/run_20261028_143005/
#   transactions.csv   every packet exchange (request, reply, status, time)
#   tests.csv          one row per test case, PASS/FAIL with the details
#   summary.csv        the numbers from the report, for plotting
#   report.md          the human-readable report
import csv, os, statistics, time

SPEED_NAME = ["2 Hz", "1 kHz", "10 kHz", "50 kHz", "100 kHz", "200 kHz", "300 kHz", "400 kHz"]
SPEED_PERIOD_MS = [500.0, 1.0, 0.1, 0.02, 0.01, 0.005, 1 / 300, 0.0025]

TEST_FIELDS = ["time", "test_id", "suite", "speed_idx", "speed", "slave", "n_bytes", "pattern",
               "expected", "got", "hw_verify", "py_verify", "mismatches", "ms", "result", "note"]
TX_FIELDS = ["time", "seq", "test_id", "cmd", "dev", "request", "reply", "status", "ms"]


def bus_ms_estimate(n_bytes, speed_idx):
    """Time the I2C bus needs for one write + read-back of n bytes (UART time not included).
    Write: addr, reg, n data. Read: addr, reg, addr, n data. 9 bits each + ~7 periods of START/STOP."""
    frames = (n_bytes + 2) + (n_bytes + 3)
    return (frames * 9 + 7) * SPEED_PERIOD_MS[speed_idx]


class RunLog:
    def __init__(self, out_dir, meta):
        stamp = time.strftime("%Y%m%d_%H%M%S")
        self.dir = os.path.join(out_dir, f"run_{stamp}")
        os.makedirs(self.dir, exist_ok=True)
        self.meta = dict(meta, started=time.strftime("%Y-%m-%d %H:%M:%S"))
        self.tests = []
        self.test_id = "-"
        self.seq = 0
        self._tx_f = open(os.path.join(self.dir, "transactions.csv"), "w", newline="")
        self._tx = csv.DictWriter(self._tx_f, fieldnames=TX_FIELDS)
        self._tx.writeheader()
        self._t_f = open(os.path.join(self.dir, "tests.csv"), "w", newline="")
        self._t = csv.DictWriter(self._t_f, fieldnames=TEST_FIELDS)
        self._t.writeheader()

    def exchange(self, ex):
        """Callback from Link: log every packet exchange."""
        self.seq += 1
        self._tx.writerow({"time": time.strftime("%H:%M:%S"), "seq": self.seq, "test_id": self.test_id,
                           "cmd": ex.cmd, "dev": f"0x{ex.dev:02X}", "request": ex.request.hex(" "),
                           "reply": ex.reply.hex(" "), "status": ex.status_name, "ms": round(ex.ms, 2)})
        self._tx_f.flush()

    def test(self, **row):
        row = {k: row.get(k, "") for k in TEST_FIELDS}
        row["time"] = time.strftime("%H:%M:%S")
        if row["speed_idx"] != "":
            row["speed"] = SPEED_NAME[row["speed_idx"]]
        if isinstance(row["ms"], float):
            row["ms"] = round(row["ms"], 2)
        self.tests.append(row)
        self._t.writerow(row)
        self._t_f.flush()
        mark = "PASS" if row["result"] == "PASS" else "FAIL"
        print(f"  {mark}  {row['test_id']:<14} {row['note']}")
        return row

    # ------------------------------------------------------------------
    def close(self):
        self._tx_f.close()
        self._t_f.close()
        self._write_report()
        return self.dir

    def _write_report(self):
        T = self.tests
        n_pass = sum(r["result"] == "PASS" for r in T)
        lines, summary = [], []
        add = lines.append
        add(f"# I2C link test report ({self.meta['started']})\n")
        add("| Setting | Value |\n| --- | --- |")
        for k, v in self.meta.items():
            add(f"| {k} | {v} |")
        add("")
        verdict = "ALL PASS" if n_pass == len(T) else f"{len(T) - n_pass} FAILED"
        add(f"**Result: {n_pass} of {len(T)} tests passed ({verdict}).**\n")

        # per suite
        add("## Tests by suite\n\n| Suite | Tests | Passed | Failed |\n| --- | --- | --- | --- |")
        for s in dict.fromkeys(r["suite"] for r in T):
            rs = [r for r in T if r["suite"] == s]
            p = sum(r["result"] == "PASS" for r in rs)
            add(f"| {s} | {len(rs)} | {p} | {len(rs) - p} |")
            summary.append({"section": "suite", "key": s, "tests": len(rs), "passed": p})
        add("")

        # round trips per speed
        rt = [r for r in T if r["suite"] == "roundtrip"]
        if rt:
            add("## Round trips by SCL speed\n")
            add("Each round trip: clear, store, write to the slave, read back, compare. "
                "Time is measured on the laptop, so it includes the UART link.\n")
            add("| Speed | Round trips | Passed | Bytes moved | Mean ms | Min ms | Max ms | "
                "Payload B/s | I2C bus ms (est., mean size) |")
            add("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
            for sp in sorted(set(r["speed_idx"] for r in rt)):
                rs = [r for r in rt if r["speed_idx"] == sp]
                ms = [float(r["ms"]) for r in rs]
                nb = [int(r["n_bytes"]) for r in rs]
                p = sum(r["result"] == "PASS" for r in rs)
                bps = sum(nb) / (sum(ms) / 1000) if sum(ms) else 0
                est = bus_ms_estimate(statistics.mean(nb), sp)
                add(f"| {SPEED_NAME[sp]} | {len(rs)} | {p} | {sum(nb)} | {statistics.mean(ms):.1f} | "
                    f"{min(ms):.1f} | {max(ms):.1f} | {bps:.0f} | {est:.2f} |")
                summary.append({"section": "speed", "key": SPEED_NAME[sp], "tests": len(rs), "passed": p,
                                "bytes": sum(nb), "mean_ms": round(statistics.mean(ms), 2),
                                "min_ms": round(min(ms), 2), "max_ms": round(max(ms), 2),
                                "payload_Bps": round(bps), "bus_ms_est": round(est, 3)})
            add("")

        # error handling + guided
        for suite, title in (("errors", "Error handling"), ("guided", "Switch-guided tests")):
            rs = [r for r in T if r["suite"] == suite]
            if rs:
                add(f"## {title}\n\n| Test | Expected | Got | Result | Note |\n| --- | --- | --- | --- | --- |")
                for r in rs:
                    add(f"| {r['test_id']} | {r['expected']} | {r['got']} | {r['result']} | {r['note']} |")
                add("")

        # file transfer
        fr = [r for r in T if r["test_id"] == "FILE"]
        if fr:
            add("## File transfer\n\n| File | Bytes | Result | Note |\n| --- | --- | --- | --- |")
            for r in fr:
                add(f"| {r['pattern']} | {r['n_bytes']} | {r['result']} | {r['note']} |")
            add("")

        # link
        ln = [r for r in T if r["suite"] == "link"]
        if ln:
            ms = [float(r["ms"]) for r in ln]
            add(f"## UART link (ECHO)\n\n{sum(r['result'] == 'PASS' for r in ln)} of {len(ln)} echoes "
                f"returned identical data; mean {statistics.mean(ms):.1f} ms per exchange.\n")

        fails = [r for r in T if r["result"] != "PASS"]
        if fails:
            add("## Failures\n\n| Test | Speed | Slave | Expected | Got | Note |\n| --- | --- | --- | --- | --- | --- |")
            for r in fails[:50]:
                add(f"| {r['test_id']} | {r['speed']} | {r['slave']} | {r['expected']} | {r['got']} | {r['note']} |")
            add("")

        add("Files in this folder: `transactions.csv` (every packet), `tests.csv` (every test), "
            "`summary.csv` (numbers above).")
        with open(os.path.join(self.dir, "report.md"), "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        keys = ["section", "key", "tests", "passed", "bytes", "mean_ms", "min_ms", "max_ms",
                "payload_Bps", "bus_ms_est"]
        with open(os.path.join(self.dir, "summary.csv"), "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=keys)
            w.writeheader()
            for row in summary:
                w.writerow({k: row.get(k, "") for k in keys})
