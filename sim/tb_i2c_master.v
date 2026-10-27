`timescale 1ns/1ps
// tb_i2c_master.v
//
// Tests i2c_master against two model slaves (0x50, 0x51) on one bus.
// Run from the repo root:
//   iverilog -o sim/tb_master.out rtl/i2c_master.v sim/i2c_slave_model.v sim/tb_i2c_master.v
//   vvp sim/tb_master.out
// Prints PASS/FAIL per check, summary at the end. Waves: tb_i2c_master.vcd

module tb_i2c_master;

    reg clk = 0;
    always #5 clk = ~clk;            // 100 MHz

    reg rst = 1;

    localparam CMD_START     = 3'd0;
    localparam CMD_WRITE     = 3'd1;
    localparam CMD_READ_ACK  = 3'd2;
    localparam CMD_READ_NACK = 3'd3;
    localparam CMD_STOP      = 3'd4;

    reg        cmd_valid = 0;
    wire       cmd_ready;
    reg  [2:0] cmd = 0;
    reg  [7:0] cmd_data = 0;
    wire       rsp_valid;
    wire [7:0] rsp_data;
    wire       rsp_nack;
    reg [24:0] t_low  = 25'd500;     // 100 kHz
    reg [24:0] t_high = 25'd500;
    reg        step_mode = 0;
    reg        step = 0;
    wire       m_scl_low, m_sda_low;
    wire       bus_busy, arb_lost;
    wire [3:0] dbg_state;
    wire [7:0] dbg_shift;

    // open-drain bus with pull-ups: high unless somebody pulls it low
    wire s0_scl_low, s0_sda_low, s1_scl_low, s1_sda_low;
    wire scl = ~(m_scl_low | s0_scl_low | s1_scl_low);
    wire sda = ~(m_sda_low | s0_sda_low | s1_sda_low);

    i2c_master dut (
        .clk(clk), .rst(rst),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd(cmd), .cmd_data(cmd_data),
        .rsp_valid(rsp_valid), .rsp_data(rsp_data), .rsp_nack(rsp_nack),
        .t_low(t_low), .t_high(t_high), .step_mode(step_mode), .step(step),
        .scl_low(m_scl_low), .sda_low(m_sda_low), .scl_in(scl), .sda_in(sda),
        .bus_busy(bus_busy), .arb_lost(arb_lost),
        .dbg_state(dbg_state), .dbg_shift(dbg_shift)
    );

    i2c_slave_model #(.ADDR(7'h50)) slave0 (.scl(scl), .sda(sda), .scl_low(s0_scl_low), .sda_low(s0_sda_low));
    i2c_slave_model #(.ADDR(7'h51)) slave1 (.scl(scl), .sda(sda), .scl_low(s1_scl_low), .sda_low(s1_sda_low));

    // ---------- checks ----------
    integer errors = 0;
    task check;
        input cond;
        input [8*64-1:0] msg;
        begin
            if (cond) $display("  PASS  %0s", msg);
            else begin
                $display("  FAIL  %0s", msg);
                errors = errors + 1;
            end
        end
    endtask

    // ---------- talking to the master ----------
    reg [7:0] r_data;
    reg       r_nack;

    // offer one command, wait till it's taken, then wait for the answer
    task send_cmd;
        input [2:0] c;
        input [7:0] d;
        begin
            cmd       <= c;
            cmd_data  <= d;
            cmd_valid <= 1'b1;
            @(posedge clk);
            while (!cmd_ready) @(posedge clk);
            cmd_valid <= 1'b0;
            @(posedge clk);
            while (!rsp_valid) @(posedge clk);
            r_data = rsp_data;
            r_nack = rsp_nack;
        end
    endtask

    reg [7:0] wbuf [0:15];
    reg [7:0] rbuf [0:15];
    reg       all_acked;

    // write n bytes from wbuf to slave addr, starting at register reg_a
    task i2c_write;
        input [6:0] addr;
        input [7:0] reg_a;
        input [4:0] n;
        integer k;
        begin
            all_acked = 1;
            send_cmd(CMD_START, 8'h00);
            send_cmd(CMD_WRITE, {addr, 1'b0});  if (r_nack) all_acked = 0;
            send_cmd(CMD_WRITE, reg_a);          if (r_nack) all_acked = 0;
            for (k = 0; k < n; k = k + 1) begin
                send_cmd(CMD_WRITE, wbuf[k]);    if (r_nack) all_acked = 0;
            end
            send_cmd(CMD_STOP, 8'h00);
        end
    endtask

    // read n bytes into rbuf: set register pointer, repeated START, read
    task i2c_read;
        input [6:0] addr;
        input [7:0] reg_a;
        input [4:0] n;
        integer k;
        begin
            all_acked = 1;
            send_cmd(CMD_START, 8'h00);
            send_cmd(CMD_WRITE, {addr, 1'b0});  if (r_nack) all_acked = 0;
            send_cmd(CMD_WRITE, reg_a);          if (r_nack) all_acked = 0;
            send_cmd(CMD_START, 8'h00);          // repeated START
            send_cmd(CMD_WRITE, {addr, 1'b1});  if (r_nack) all_acked = 0;
            for (k = 0; k < n; k = k + 1) begin
                send_cmd((k == n-1) ? CMD_READ_NACK : CMD_READ_ACK, 8'h00);
                rbuf[k] = r_data;
            end
            send_cmd(CMD_STOP, 8'h00);
        end
    endtask

    task pulse_step;
        begin
            repeat (20) @(posedge clk);
            step <= 1'b1;
            @(posedge clk);
            step <= 1'b0;
        end
    endtask

    // ---------- SCL timing monitor ----------
    // shortest low / high / rise-to-rise period and longest low,
    // since the last clear_timing
    realtime t_rise = 0, t_fall = 0;
    real     min_low, min_high, max_low, min_period;
    reg      seen_rise = 0, seen_fall = 0;

    task clear_timing;
        begin
            min_low = 1e12; min_high = 1e12; max_low = 0; min_period = 1e12;
            seen_rise = 0;  seen_fall = 0;
        end
    endtask

    always @(posedge scl) begin
        if (seen_fall && ($realtime - t_fall) < min_low)    min_low    = $realtime - t_fall;
        if (seen_fall && ($realtime - t_fall) > max_low)    max_low    = $realtime - t_fall;
        if (seen_rise && ($realtime - t_rise) < min_period) min_period = $realtime - t_rise;
        t_rise = $realtime;
        seen_rise = 1;
    end

    always @(negedge scl) begin
        if (seen_rise && ($realtime - t_rise) < min_high) min_high = $realtime - t_rise;
        t_fall = $realtime;
        seen_fall = 1;
    end

    // ---------- the tests ----------
    initial begin
        $dumpfile("tb_i2c_master.vcd");
        $dumpvars(0, tb_i2c_master);
        clear_timing;

        repeat (5) @(posedge clk);
        rst <= 0;
        repeat (5) @(posedge clk);

        $display("Test 1: write 3 bytes to 0x50 @ 100 kHz");
        wbuf[0] = 8'h11; wbuf[1] = 8'h22; wbuf[2] = 8'h33;
        clear_timing;
        i2c_write(7'h50, 8'h10, 3);
        check(all_acked, "every byte ACKed");
        check(slave0.mem[8'h10] == 8'h11 && slave0.mem[8'h11] == 8'h22 && slave0.mem[8'h12] == 8'h33,
              "slave 0x50 has 11 22 33 at reg 0x10");
        check(min_low  >= 4700.0, "SCL low  >= 4.7 us (spec)");
        check(min_high >= 4000.0, "SCL high >= 4.0 us (spec)");
        check(min_period >= 10000.0 && min_period <= 10100.0, "SCL period ~10 us");
        $display("        low %.0f ns, high %.0f ns, period %.0f ns", min_low, min_high, min_period);

        $display("Test 2: read them back with repeated START");
        i2c_read(7'h50, 8'h10, 3);
        check(all_acked, "address and register ACKed");
        check(rbuf[0] == 8'h11 && rbuf[1] == 8'h22 && rbuf[2] == 8'h33, "read back 11 22 33");

        $display("Test 3: second slave 0x51");
        wbuf[0] = 8'hC3;
        i2c_write(7'h51, 8'h20, 1);
        check(all_acked, "0x51 ACKed");
        check(slave1.mem[8'h20] == 8'hC3, "0x51 got C3");
        check(slave0.mem[8'h20] == 8'h00, "0x50 didn't touch it");

        $display("Test 4: nobody at 0x42");
        send_cmd(CMD_START, 8'h00);
        send_cmd(CMD_WRITE, {7'h42, 1'b0});
        check(r_nack == 1'b1, "address NACKed");
        send_cmd(CMD_STOP, 8'h00);
        check(!bus_busy, "bus released after STOP");

        $display("Test 5: 400 kHz write + read");
        t_low = 25'd150; t_high = 25'd100;
        wbuf[0] = 8'hA5; wbuf[1] = 8'h5A; wbuf[2] = 8'hFF; wbuf[3] = 8'h00;
        clear_timing;
        i2c_write(7'h50, 8'h40, 4);
        i2c_read(7'h50, 8'h40, 4);
        check(all_acked, "all ACKed at 400 kHz");
        check(rbuf[0] == 8'hA5 && rbuf[1] == 8'h5A && rbuf[2] == 8'hFF && rbuf[3] == 8'h00,
              "read back A5 5A FF 00");
        check(min_low  >= 1300.0, "SCL low  >= 1.3 us (fast-mode spec)");
        check(min_high >=  600.0, "SCL high >= 0.6 us (fast-mode spec)");
        check(min_period >= 2500.0 && min_period <= 2600.0, "SCL period ~2.5 us");
        $display("        low %.0f ns, high %.0f ns, period %.0f ns", min_low, min_high, min_period);
        t_low = 25'd500; t_high = 25'd500;

        $display("Test 6: clock stretching (slave holds SCL 8 us)");
        slave0.stretch_ns = 8000;
        wbuf[0] = 8'h77;
        clear_timing;
        i2c_write(7'h50, 8'h80, 1);
        slave0.stretch_ns = 0;
        check(all_acked && slave0.mem[8'h80] == 8'h77, "data right with stretching");
        check(max_low  >= 8000.0, "slave really held SCL low");
        check(min_high >= 5000.0, "master still gave full high time after stretch");

        $display("Test 7: step mode, START = 4 steps");
        step_mode = 1;
        fork
            send_cmd(CMD_START, 8'h00);
            begin
                pulse_step; pulse_step; pulse_step;
                repeat (50) @(posedge clk);
                check(dbg_state == 4'd1, "START still running after 3 steps");
                pulse_step;
            end
        join
        check(bus_busy, "START done after 4th step");
        step_mode = 0;
        send_cmd(CMD_STOP, 8'h00);

        $display("Test 8: WRITE without START");
        send_cmd(CMD_WRITE, 8'hAA);
        check(r_nack == 1'b1 && !bus_busy, "rejected with nack, bus untouched");

        $display("");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d CHECK(S) FAILED", errors);
        $finish;
    end

    // in case something hangs
    initial begin
        #20_000_000;
        $display("TIMEOUT - stuck in state %0d", dbg_state);
        $finish;
    end

endmodule