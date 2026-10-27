@echo off
rem run_all.bat - runs every testbench from the repo top folder. Each should show PASS lines and no FAIL.
if not exist out mkdir out
echo ===== tb_debounce
iverilog -o out\tb_debounce.out rtl\debounce.v sim\tb_debounce.v && vvp out\tb_debounce.out | findstr /C:"PASS" /C:"FAIL" /C:"Summary"
echo ===== tb_i2c_master
iverilog -o out\tb_i2c_master.out rtl\i2c_master.v sim\i2c_slave_model.v sim\tb_i2c_master.v && vvp out\tb_i2c_master.out | findstr /C:"PASS" /C:"FAIL" /C:"Summary"
echo ===== tb_mode_ctrl
iverilog -o out\tb_mode_ctrl.out rtl\debounce.v rtl\mode_ctrl.v rtl\i2c_master.v sim\i2c_slave_model.v sim\tb_mode_ctrl.v && vvp out\tb_mode_ctrl.out | findstr /C:"PASS" /C:"FAIL" /C:"Summary"
echo ===== tb_i2c_seq
iverilog -o out\tb_i2c_seq.out rtl\i2c_seq.v rtl\i2c_master.v sim\i2c_slave_model.v sim\tb_i2c_seq.v && vvp out\tb_i2c_seq.out | findstr /C:"PASS" /C:"FAIL" /C:"Summary"
echo ===== tb_i2c_slave
iverilog -o out\tb_i2c_slave.out rtl\i2c_slave.v sim\tb_i2c_slave.v && vvp out\tb_i2c_slave.out | findstr /C:"PASS" /C:"FAIL" /C:"Summary"
echo ===== tb_bus
iverilog -o out\tb_bus.out rtl\i2c_master.v rtl\i2c_slave.v sim\tb_bus.v && vvp out\tb_bus.out | findstr /C:"PASS" /C:"FAIL" /C:"Summary"
echo ===== tb_i2c_seq_neer
iverilog -o out\tb_i2c_seq_neer.out rtl\i2c_seq.v rtl\i2c_master.v rtl\i2c_slave.v sim\tb_i2c_seq_neer.v && vvp out\tb_i2c_seq_neer.out | findstr /C:"PASS" /C:"FAIL" /C:"Summary"
echo ===== tb_store_readback
iverilog -o out\tb_store_readback.out rtl\i2c_seq.v rtl\i2c_master.v rtl\i2c_slave.v sim\tb_store_readback.v && vvp out\tb_store_readback.out | findstr /C:"PASS" /C:"FAIL" /C:"Summary"
echo ===== tb_system
iverilog -o out\tb_system.out rtl\debounce.v rtl\mode_ctrl.v rtl\i2c_seq.v rtl\i2c_master.v rtl\i2c_slave.v rtl\seg7.v rtl\top_s.v sim\tb_system.v && vvp out\tb_system.out | findstr /C:"PASS" /C:"FAIL" /C:"Summary"
echo ===== tb_uart_loop
iverilog -o out\tb_uart_loop.out rtl\uart_rx.v rtl\uart_tx.v rtl\crc8.v sim\tb_uart_loop.v && vvp out\tb_uart_loop.out | findstr /C:"PASS" /C:"FAIL" /C:"Summary"
echo ===== tb_uart_bridge
iverilog -o out\tb_uart_bridge.out rtl\uart_rx.v rtl\uart_tx.v rtl\crc8.v rtl\uart_bridge.v rtl\i2c_seq.v rtl\i2c_master.v rtl\i2c_slave.v sim\i2c_slave_model.v sim\tb_uart_bridge.v && vvp out\tb_uart_bridge.out | findstr /C:"PASS" /C:"FAIL" /C:"Summary"
echo ===== tb_full
iverilog -o out\tb_full.out rtl\debounce.v rtl\mode_ctrl.v rtl\i2c_seq.v rtl\i2c_master.v rtl\uart_rx.v rtl\uart_tx.v rtl\crc8.v rtl\uart_bridge.v rtl\seg7.v rtl\top_m.v rtl\i2c_slave.v rtl\top_s.v sim\tb_full.v && vvp out\tb_full.out | findstr /C:"PASS" /C:"FAIL" /C:"Summary"
del /Q *.vcd 2>nul
