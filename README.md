# I2C Controller on Basys 3: final files

Two Basys 3 boards. Board M (master) talks to the laptop over USB-UART and runs the I2C master;
Board S holds two I2C slaves (0x50, 0x51). The laptop stores bytes in Board M, writes them to a
slave, reads them back and verifies them, in hardware and in Python.

## Files

| Folder | File | What | Owner |
| --- | --- | --- | --- |
| rtl | i2c_master.v | Byte-level I2C master, 4-quarter bit timing, clock stretching, step mode | Keval |
| rtl | i2c_seq.v | Stores 32 bytes, runs write / read-back, verifies, gated by SW15 | Keval |
| rtl | mode_ctrl.v | Switches: SW15 protocol ON, SW2-0 speed (parameterized 2 Hz-400 kHz), step, debug | Keval |
| rtl | debounce.v | Switch / button debouncer (start values so it never sims as X) | Keval |
| rtl | top_m.v | Board M top level: UART + bridge + sequencer + master, pins, LEDs, display | Keval |
| rtl | uart_rx.v, uart_tx.v, crc8.v | 115200 8N1 UART, CRC-8 (poly 0x07) | starters |
| rtl | uart_bridge.v | Packet parser / reply builder between UART and sequencer | Abhirup |
| rtl | i2c_slave.v | One slave: filter, FSM, 240-byte memory, registers F0-F2 | Neer |
| rtl | seg7.v | 4-digit display driver | Neer |
| rtl | top_s.v | Board S top level: two slaves, LEDs, display | Neer |
| constraints | basys3_m.xdc / basys3_s.xdc | Pins for each board; PULLUP on SCL/SDA enabled on both | Keval / Neer |
| sim | tb_*.v, i2c_slave_model.v | 12 self-checking testbenches (simulation only) | all |
| host | i2c_demo.py + helpers | Laptop side: manual demo mode and automatic CSV/report mode | starters, extended |

## Vivado (part xc7a35tcpg236-1), one project per board
- Board M: rtl/ debounce, mode_ctrl, i2c_seq, i2c_master, uart_rx, uart_tx, crc8, uart_bridge, seg7, top_m
  + constraints/basys3_m.xdc. Top = top_m.
- Board S: rtl/ debounce, i2c_slave, seg7, top_s + constraints/basys3_s.xdc. Top = top_s.
- Never add anything from sim/ (testbenches and the slave model can't be synthesized).
- After implementation: timing summary WNS >= 0 at 100 MHz, then generate the bitstream.

## Wiring
JA1-JA1 (SCL), JA2-JA2 (SDA), JA5-JA5 (GND). No 3.3 V between boards. USB to both boards;
only Board M's COM port is used by the laptop.

## Simulation
Run `run_all.bat` from this folder (Icarus Verilog). All 12 testbenches pass:
tb_debounce 8, tb_i2c_master 23, tb_mode_ctrl 21, tb_i2c_seq 21, tb_i2c_slave 12, tb_bus 12,
tb_i2c_seq_neer 21, tb_store_readback 25, tb_system 29, tb_uart_loop 1, tb_uart_bridge 15, tb_full 18.

## Laptop
See host/README.md, and OPERATING.md for running the boards. `python i2c_demo.py manual --port COM5` for the demo,
`python i2c_demo.py auto --port COM5 --ladder 1-7 --file test.bin` for the logged report.
