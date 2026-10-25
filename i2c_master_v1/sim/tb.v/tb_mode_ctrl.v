`timescale 1ns/1ps
// tb_mode_ctrl.v
//
// Checks mode_ctrl on its own and together with the master:
//   - the speed table numbers for all 8 speeds
//   - measured SCL period on the bus for speeds 1-7 (2 Hz would need
//     0.5 s of sim time per period, so only its numbers are checked)
//   - PC/board source switch, start button, step mode gating, debug pins
// Debounce is set to 16 clocks so it runs fast.
// Run:
//   iverilog -o sim/tb_mode_ctrl.out rtl/debounce.v rtl/mode_ctrl.v rtl/i2c_master.v sim/models/i2c_slave_model.v sim/tb_mode_ctrl.v
//   vvp sim/tb_mode_ctrl.out

module tb_mode_ctrl;

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;

    localparam DEB_N = 16;

    localparam CMD_START = 3'd0;
    localparam CMD_WRITE = 3'd1;
    localparam CMD_STOP  = 3'd4;

    // ---------- mode_ctrl ----------
    reg  [15:0] sw = 16'h0000;
    reg         btn_start = 0;
    reg         btn_step  = 0;
    reg  [2:0]  pc_speed_idx = 3'd4;

    wire        src_sel;
    wire [2:0]  speed_idx;
    wire [24:0] t_low, t_high;
    wire        step_mode, step, start_pulse, slave_sel, rw;
    wire        dbg_en, dbg_scl_low, dbg_sda_low;

    mode_ctrl #(.DEB_N(DEB_N)) u_mode (
        .clk(clk), .rst(rst),
        .sw(sw), .btn_start(btn_start), .btn_step(btn_step), .pc_speed_idx(pc_speed_idx),
        .src_sel(src_sel), .speed_idx(speed_idx), .t_low(t_low), .t_high(t_high),
        .step_mode(step_mode), .step(step), .start_pulse(start_pulse),
        .slave_sel(slave_sel), .rw(rw),
        .dbg_en(dbg_en), .dbg_scl_low(dbg_scl_low), .dbg_sda_low(dbg_sda_low)
    );

    // ---------- master + one slave, so we can measure real SCL ----------
    reg        cmd_valid = 0;
    wire       cmd_ready;
    reg  [2:0] cmd = 0;
    reg  [7:0] cmd_data = 0;
    wire       rsp_valid, rsp_nack;
    wire [7:0] rsp_data;
    wire       m_scl_low, m_sda_low, s_scl_low, s_sda_low;

    wire scl = ~(m_scl_low | s_scl_low);
    wire sda = ~(m_sda_low | s_sda_low);

    i2c_master u_master (
        .clk(clk), .rst(rst),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd(cmd), .cmd_data(cmd_data),
        .rsp_valid(rsp_valid), .rsp_data(rsp_data), .rsp_nack(rsp_nack),
        .t_low(t_low), .t_high(t_high), .step_mode(step_mode), .step(step),
        .scl_low(m_scl_low), .sda_low(m_sda_low), .scl_in(scl), .sda_in(sda),
        .bus_busy(), .arb_lost(), .dbg_state(), .dbg_shift()
    );

    i2c_slave_model #(.ADDR(7'h50)) slave0 (
        .scl(scl), .sda(sda), .scl_low(s_scl_low), .sda_low(s_sda_low)
    );

    // ---------- helpers ----------
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

    // give the debouncers time to accept a new switch value
    task settle;
        begin
            repeat (DEB_N + 10) @(posedge clk);
        end
    endtask

    // press and release a button, held long enough to get through debounce
    task press_start;
        begin
            btn_start = 1; settle;
            btn_start = 0; settle;
        end
    endtask

    integer starts = 0;
    always @(posedge clk) if (start_pulse) starts = starts + 1;

    reg r_nack;
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
            r_nack = rsp_nack;
        end
    endtask

    // shortest rise-to-rise SCL period since clear_timing
    realtime t_rise = 0;
    real     min_period;
    reg      seen_rise = 0;

    task clear_timing;
        begin
            min_period = 1e15;
            seen_rise  = 0;
        end
    endtask

    always @(posedge scl) begin
        if (seen_rise && ($realtime - t_rise) < min_period) min_period = $realtime - t_rise;
        t_rise = $realtime;
        seen_rise = 1;
    end

    // what the table should give, worked out by hand:
    // period = CLK_HZ / hz, t_low = period * low% / 100, t_high = period - t_low - 2
    reg [24:0] exp_lo [0:7];
    reg [24:0] exp_hi [0:7];
    real       exp_ns [0:7];   // expected period on the bus

    integer i;
    real    diff;

    initial begin
        exp_lo[0] = 25_000_000; exp_hi[0] = 24_999_998; exp_ns[0] = 500_000_000.0;
        exp_lo[1] = 50_000;     exp_hi[1] = 49_998;     exp_ns[1] = 1_000_000.0;
        exp_lo[2] = 5_000;      exp_hi[2] = 4_998;      exp_ns[2] = 100_000.0;
        exp_lo[3] = 1_000;      exp_hi[3] = 998;        exp_ns[3] = 20_000.0;
        exp_lo[4] = 500;        exp_hi[4] = 498;        exp_ns[4] = 10_000.0;
        exp_lo[5] = 250;        exp_hi[5] = 248;        exp_ns[5] = 5_000.0;
        exp_lo[6] = 166;        exp_hi[6] = 165;        exp_ns[6] = 3_330.0;   // 333 clocks, 300.3 kHz
        exp_lo[7] = 150;        exp_hi[7] = 98;         exp_ns[7] = 2_500.0;
    end

    initial begin
        $dumpfile("tb_mode_ctrl.vcd");
        $dumpvars(0, tb_mode_ctrl);

        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        $display("Test 1: speed table (board control)");
        sw[15] = 1;
        for (i = 0; i < 8; i = i + 1) begin
            sw[2:0] = i;
            settle;
            check(t_low == exp_lo[i] && t_high == exp_hi[i], "t_low / t_high match the table");
            $display("        speed %0d: t_low %0d, t_high %0d", i, t_low, t_high);
        end

        $display("Test 2: PC in control ignores SW2-0");
        sw[15] = 0; sw[2:0] = 3'd7; pc_speed_idx = 3'd6;
        settle;
        check(src_sel == 0 && speed_idx == 3'd6, "speed comes from pc_speed_idx");
        check(t_low == exp_lo[6] && t_high == exp_hi[6], "300 kHz numbers selected");

        $display("Test 3: measured SCL period, speeds 1-7");
        sw[15] = 1;
        for (i = 1; i < 8; i = i + 1) begin
            sw[2:0] = i;
            settle;
            clear_timing;
            send_cmd(CMD_START, 8'h00);
            send_cmd(CMD_WRITE, 8'hA0);
            send_cmd(CMD_STOP,  8'h00);
            diff = min_period - exp_ns[i];
            if (diff < 0) diff = -diff;
            check(diff <= 10.0 && r_nack == 0, "period matches and slave ACKed");
            $display("        speed %0d: period %.0f ns (expected %.0f)", i, min_period, exp_ns[i]);
        end

        $display("Test 4: start button");
        starts = 0;
        sw[15] = 1; settle;
        press_start;
        check(starts == 1, "board control: one press = one start_pulse");
        sw[15] = 0; settle;
        press_start;
        check(starts == 1, "PC control: button ignored");
        sw[15] = 1; sw[14] = 1; settle;
        press_start;
        check(starts == 1, "debug mode: button ignored");
        sw[14] = 0; settle;

        $display("Test 5: step mode only under board control");
        sw[5] = 1; sw[15] = 1; settle;
        check(step_mode == 1, "SW5 + board control = step mode");
        sw[15] = 0; settle;
        check(step_mode == 0, "SW5 + PC control = no step mode");
        sw[5] = 0; settle;

        $display("Test 6: slave select, R/W, debug pins");
        sw[3] = 1; sw[4] = 1; settle;
        check(slave_sel == 1 && rw == 1, "SW3 / SW4 come through");
        sw[14] = 1; sw[13] = 0; sw[12] = 1; settle;
        check(dbg_en == 1 && dbg_scl_low == 1 && dbg_sda_low == 0,
              "debug: SW13 down pulls SCL, SW12 up releases SDA");

        $display("");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d CHECK(S) FAILED", errors);
        $finish;
    end

endmodule