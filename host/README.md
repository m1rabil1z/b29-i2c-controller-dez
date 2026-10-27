# Laptop side (pyserial)

Files: `i2c_demo.py` (run this), `protocol.py` (packets, CRC-8), `link.py` (one request,
one reply, never crashes), `report.py` (CSV logs + report), `fake_board.py` (no-hardware testing).

Install once: `pip install pyserial`. Find Board M's port: `python -m serial.tools.list_ports`.

## Manual mode: live demo, watch the boards
    python i2c_demo.py manual --port COM5            (add --log to also save every packet)
    i2c> store 11 22 33        put bytes in Board M (hex, or "TEXT" in quotes; max 32)
    i2c> write 50              write them to slave 0x50 (waits until Board M SW15 is ON)
    i2c> read 50               read back and verify (Board M LD8 = OK, LD9 = bad)
    i2c> rt 51 "HELLO"         clear + store + write, pauses so you can look at Board S, then reads back
    i2c> echo 01 02 / clear / show / raw <hex> / help / quit

## Automatic mode: full test plan, CSV log + report
    python i2c_demo.py auto --port COM5 --speed 4 --rounds 20 --file test.bin
    python i2c_demo.py auto --port COM5 --ladder 1-7 --rounds 20      (asks you to change SW2-0)
    python i2c_demo.py auto --port COM5 --no-prompts                  (unattended, skips switch tests)
Suites (choose with --suites): link (ECHO), roundtrip (random data, 6 patterns, both slaves),
errors (NACK, empty, bad CRC, store full, unknown command, cut-off packet, recovery),
guided (protocol OFF hold, forced NACK, invert: it tells you which switch to flip), file (SHA-256 checked).
--speed must match Board M's SW2-0 setting; it is only used for the log and the timeouts.

Each run writes logs/run_<date_time>/ with transactions.csv, tests.csv, summary.csv and report.md.
Exit code 0 = every test passed.

## Without hardware
    python i2c_demo.py auto --fake --file test.bin
    python i2c_demo.py auto --fake --fault-rate 0.1      (injects lost replies and corrupted bytes)
    python i2c_demo.py manual --fake
