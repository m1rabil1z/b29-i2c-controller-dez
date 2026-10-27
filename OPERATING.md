# Operating the boards

## 1. Set up (once per session)
1. Program both boards: Vivado Hardware Manager -> Open Target -> Auto Connect -> Program Device.
   top_m.bit on Board M, top_s.bit on Board S. (Lost at power-off; for permanent, write a .bin
   to the QSPI flash and set jumper JP1 to QSPI.)
2. Wire: JA1-JA1 (SCL), JA2-JA2 (SDA), JA5-JA5 (GND). Never connect 3.3 V between boards.
3. All switches down on both boards. Board M speed 100 kHz: SW2 up, SW1 down, SW0 down.
4. Press BTNU on both boards.
5. Find Board M's COM port: `python -m serial.tools.list_ports`.

Idle: Board M LD15 + LD14 on, display `0040`. Board S display `0000`, SDA/SCL dots lit.

## 2. Controls
Board M
| Control | Function |
| --- | --- |
| SW15 | Protocol ON (write/read requests wait until it is up) |
| SW2-0 | Speed: 000 2 Hz, 001 1 kHz, 010 10 kHz, 011 50 kHz, 100 100 kHz, 101 200 kHz, 110 300 kHz, 111 400 kHz |
| SW5 + BTNR | Step mode: one press = one quarter of a bit |
| SW14 (+SW13/SW12) | Debug: SW13/SW12 drive SCL/SDA by hand (up = high); forces protocol off |
| BTNU | Reset |
| LD15 / LD14 | SCL / SDA |
| LD13, LD12, LD11 | Protocol ON, busy, pending |
| LD10, LD9, LD8 | NACK, verify bad, verify OK |
| LD7-0 | Last byte stored (or read back) |
| Display | bytes stored, speed, result (0 OK, 2 NACK, 8 mismatch, 9 nothing stored) |

Board S
| Control | Function |
| --- | --- |
| SW15 / SW14 | Force NACK on 0x50 / 0x51 |
| SW13 | Invert reads (test corruption) |
| SW7-0 | Value readable at register 0xF1 |
| BTNU | Reset (display clears, stored data stays) |
| LD15-8, digits 3-2 | Last byte written to 0x50 |
| LD7-0, digits 1-0 | Last byte written to 0x51 |
| DP3 / DP1 | 0x50 / 0x51 addressed |
| DP2 / DP0 | Live SDA / SCL |

## 3. Bring-up checks, in order
1. Wiring (no laptop): Board M SW14 up, SW13 up; flip SW12 down/up -> Board S DP2 follows. SW14 down.
2. USB link: `python i2c_demo.py manual --port COM5`, then `echo 01 02` -> OK, same bytes.
3. One write: SW15 up, then `rt 50 "HI"` -> Board S LD15-8 shows 49, read-back MATCH.

## 4. Live demo (manual mode)
    i2c> store "HELLO"     Board M LD7-0 = 4F, display 05 4 0
    i2c> write 50          SW15 off -> waits (LD11 pending); flip SW15 up -> runs
                           Board S LD15-8 and digits 3-2 show 4F
    i2c> read 50           Board M LD8 on; laptop shows HELLO, Board M check OK, laptop MATCH
- Watch the bits: SW2-0 = 000 (2 Hz), `rt 50 "A"` (about 45 s); LD15/LD14 blink bit by bit.
- Step mode: SW5 up, press BTNR (4 presses per bit).
- Errors: Board S SW15 up + `write 50` -> NACK (LD10, display 2).
  Board S SW13 up + `read 50` -> MISMATCH (LD9, display 8). Switches back down after.

## 5. Logged run (automatic mode)
Before starting: Board M SW15 UP, SW14 down, SW2-0 = the speed given in --speed.
    python i2c_demo.py auto --port COM5 --speed 4 --rounds 20 --file test.bin
    python i2c_demo.py auto --port COM5 --ladder 1-7 --rounds 20
- --ladder pauses before each speed: set SW2-0 as told, press Enter.
- Guided tests pause and say which switch to flip; flip it, press Enter.
- --no-prompts: unattended, skips the guided tests.
Output: logs/run_<date_time>/ with report.md, tests.csv, transactions.csv, summary.csv.
Exit code 0 = everything passed. Highest speed where all round trips pass = headline result.

## 6. Troubleshooting
| Symptom | Likely cause | Fix |
| --- | --- | --- |
| "Access is denied" opening the port | Another program has the COM port | Close PuTTY / other serial terminals |
| Every command NO_REPLY | Wrong port, or Board M not programmed | Check list_ports, reprogram, BTNU |
| `write` never finishes | SW15 off, or SW14 debug on | SW15 up, SW14 down |
| Every write NACK | Wiring, missing GND, Board S not programmed/reset | Check JA1/JA2/JA5, BTNU on Board S |
| Mismatch only at high speeds | Internal pull-ups too weak | Use a lower speed; report the highest that passes |
| LEDs/display stuck | - | BTNU on both boards |
| TimeoutError in auto mode | SW15 was off at the start | SW15 up, start again |
