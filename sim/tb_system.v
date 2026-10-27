`timescale 1ns/1ps
// tb_system.v
//
// The whole setup in one simulation:
//
//   PC        tasks below (stand-in for pyserial + Abhirup's UART bridge)
//    |
//   Board M   mode_ctrl + i2c_seq + i2c_master            (Keval, v2)
//             + the pin logic top_m.v will have: open-drain pins, debug mux
//    |
//   I2C bus   two wires with pull-ups (tri1 = PULLUP in the XDC)
//    |
//   Board S   top_s: two i2c_slave + seg7 + debounce      (Neer, real top level)
//
// Each board runs on its own clock (slightly different frequency and phase,
// like two real Basys 3s). Debounce is cut to 16 clocks and the display
// refresh sped up so the whole run takes about a minute.
//
// Run (from the integration folder):
//   iverilog -o sim/tb_system.out rtl/debounce.v rtl/mode_ctrl.v rtl/i2c_seq.v rtl/i2c_master.v rtl/i2c_slave.v rtl/seg7.v rtl/top_s.v sim/tb_system.v
//   vvp sim/tb_system.out
// Waveforms: add -DDUMP to the iverilog line (the file gets big).

module tb_system;

    // ======================= clocks =======================
    reg clk_m = 0;
    always #5 clk_m = ~clk_m;                         // Board M, 100 MHz

    reg clk_s = 0;
    initial begin #3; forever #5.001 clk_s = ~clk_s; end   // Board S, 0.02% slower, other phase

    // ======================= Board M =======================
    reg        rst_m  = 1;
    reg [15:0] sw_m   = 16'h0004;    // SW2-0 = 4 (100 kHz), SW15 protocol OFF
    reg        btnr_m = 0;           // step button

    wire        run_en, step_mode, step, dbg_en, dbg_scl_low, dbg_sda_low;
    wire [2:0]  speed_idx;
    wire [24:0] t_low, t_high;

    mode_ctrl #(.DEB_N(16)) u_mode (
        .clk(clk_m), .rst(rst_m), .sw(sw_m), .btn_step(btnr_m),
        .run_en(run_en), .speed_idx(speed_idx), .t_low(t_low), .t_high(t_high),
        .step_mode(step_mode), .step(step),
        .dbg_en(dbg_en), .dbg_scl_low(dbg_scl_low), .dbg_sda_low(dbg_sda_low)
    );

    // PC side of the sequencer (Abhirup's parser will drive these)
    reg        store_valid = 0, clear = 0, req_valid = 0, req_rw = 0;
    reg  [7:0] store_byte  = 0;
    reg  [6:0] req_addr    = 0;
    wire       rd_valid, done, pending, busy, verify_ok, verify_bad, nack_err, empty_err;
    wire [7:0] rd_byte, status, count, last_stored, last_read, mism_cnt;

    wire       m_cmd_valid, m_cmd_ready, m_rsp_valid, m_rsp_nack;
    wire [2:0] m_cmd;
    wire [7:0] m_cmd_data, m_rsp_data;
    wire       m_scl_low, m_sda_low;

    i2c_seq #(.DEPTH(32)) u_seq (
        .clk(clk_m), .rst(rst_m),
        .store_valid(store_valid), .store_byte(store_byte), .clear(clear),
        .req_valid(req_valid), .req_addr(req_addr), .req_rw(req_rw), .run_en(run_en),
        .m_cmd_valid(m_cmd_valid), .m_cmd_ready(m_cmd_ready), .m_cmd(m_cmd), .m_cmd_data(m_cmd_data),
        .m_rsp_valid(m_rsp_valid), .m_rsp_data(m_rsp_data), .m_rsp_nack(m_rsp_nack),
        .rd_valid(rd_valid), .rd_byte(rd_byte), .done(done), .status(status),
        .count(count), .pending(pending), .busy(busy), .last_stored(last_stored), .last_read(last_read),
        .verify_ok(verify_ok), .verify_bad(verify_bad), .nack_err(nack_err), .empty_err(empty_err),
        .mism_cnt(mism_cnt)
    );

    i2c_master u_master (
        .clk(clk_m), .rst(rst_m),
        .cmd_valid(m_cmd_valid), .cmd_ready(m_cmd_ready), .cmd(m_cmd), .cmd_data(m_cmd_data),
        .rsp_valid(m_rsp_valid), .rsp_data(m_rsp_data), .rsp_nack(m_rsp_nack),
        .t_low(t_low), .t_high(t_high), .step_mode(step_mode), .step(step),
        .scl_low(m_scl_low), .sda_low(m_sda_low), .scl_in(scl), .sda_in(sda),
        .bus_busy(), .arb_lost(), .dbg_state(), .dbg_shift()
    );

    // ---- Board M pins: exactly what top_m.v will do ----
    wire m_scl_pull = dbg_en ? dbg_scl_low : m_scl_low;   // debug mode: switches drive the pins
    wire m_sda_pull = dbg_en ? dbg_sda_low : m_sda_low;

    // ======================= the bus =======================
    tri1 scl, sda;                                  // pulled up when nobody pulls (XDC PULLUP)
    assign scl = m_scl_pull ? 1'b0 : 1'bz;          // Board M open-drain
    assign sda = m_sda_pull ? 1'b0 : 1'bz;

    // ======================= Board S =======================
    reg        btnu_s = 0;
    reg [15:0] sw_s   = 16'h00A5;    // SW7-0 = A5 (readable at 0xF1), everything else off
    wire [15:0] led_s;
    wire [6:0]  seg_s;
    wire        dp_s;
    wire [3:0]  an_s;

    top_s #(.DEB_N(16)) u_board_s (
        .clk(clk_s), .btnU(btnu_s), .sw(sw_s),
        .led(led_s), .seg(seg_s), .dp(dp_s), .an(an_s),
        .scl_pin(scl), .sda_pin(sda)
    );
    defparam u_board_s.u_seg7.TICKS_PER_DIGIT = 20;  // refresh the display fast in sim

    // ---- read Board S's 7-segment display the way your eye would ----
    function [3:0] seg2hex;
        input [6:0] s;
        case (s)
            7'b100_0000: seg2hex = 4'h0;  7'b111_1001: seg2hex = 4'h1;
            7'b010_0100: seg2hex = 4'h2;  7'b011_0000: seg2hex = 4'h3;
            7'b001_1001: seg2hex = 4'h4;  7'b001_0010: seg2hex = 4'h5;
            7'b000_0010: seg2hex = 4'h6;  7'b111_1000: seg2hex = 4'h7;
            7'b000_0000: seg2hex = 4'h8;  7'b001_0000: seg2hex = 4'h9;
            7'b000_1000: seg2hex = 4'hA;  7'b000_0011: seg2hex = 4'hB;
            7'b100_0110: seg2hex = 4'hC;  7'b010_0001: seg2hex = 4'hD;
            7'b000_0110: seg2hex = 4'hE;  7'b000_1110: seg2hex = 4'hF;
            default:     seg2hex = 4'hx;
        endcase
    endfunction

    reg [3:0] digit [0:3];
    reg [3:0] dot;               // dot[3] = 0x50 addressed, dot[2] = SDA, dot[1] = 0x51 addressed, dot[0] = SCL
    always @(posedge clk_s) case (an_s)
        4'b1110: begin digit[0] <= seg2hex(seg_s); dot[0] <= ~dp_s; end
        4'b1101: begin digit[1] <= seg2hex(seg_s); dot[1] <= ~dp_s; end
        4'b1011: begin digit[2] <= seg2hex(seg_s); dot[2] <= ~dp_s; end
        4'b0111: begin digit[3] <= seg2hex(seg_s); dot[3] <= ~dp_s; end
    endcase
    wire [15:0] display = {digit[3], digit[2], digit[1], digit[0]};

    // ======================= helpers =======================
    integer errors = 0;
    task check;
        input cond;
        input [8*64-1:0] msg;
        begin
            if (cond) $display("  PASS  %0s", msg);
            else begin $display("  FAIL  %0s", msg); errors = errors + 1; end
        end
    endtask

    task settle_m; repeat (40)  @(posedge clk_m); endtask   // switch change gets through debounce
    task settle_s; repeat (40)  @(posedge clk_s); endtask
    task look;     repeat (200) @(posedge clk_s); endtask   // let the display refresh a few times

    task press_btnu; begin btnu_s = 1; settle_s; btnu_s = 0; settle_s; end endtask
    task press_btnr; begin btnr_m = 1; settle_m; btnr_m = 0; settle_m; end endtask

    // what the PC sends / gets back
    reg [7:0] pat [0:31];
    reg [7:0] got [0:31];
    integer   nrd = 0;
    always @(posedge clk_m) if (rd_valid) begin got[nrd] = rd_byte; nrd = nrd + 1; end

    integer k, seed;

    task pc_store;                   // clear the buffer, send pat[0..n-1]
        input integer n;
        begin
            @(posedge clk_m); clear <= 1; @(posedge clk_m); clear <= 0;
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk_m); store_valid <= 1; store_byte <= pat[k];
            end
            @(posedge clk_m); store_valid <= 0; @(posedge clk_m);
        end
    endtask

    task pc_request;                 // ask for a write (0) or read (1), don't wait
        input [6:0] a;
        input       r;
        begin
            nrd = 0;
            @(posedge clk_m); req_valid <= 1; req_addr <= a; req_rw <= r;
            @(posedge clk_m); req_valid <= 0;
        end
    endtask

    task wait_done;
        begin
            @(posedge clk_m); while (!done) @(posedge clk_m);
            @(posedge clk_m);
        end
    endtask

    task pc_transfer;                // request + wait
        input [6:0] a;
        input       r;
        begin pc_request(a, r); wait_done; end
    endtask

    function got_ok;                 // read data == pat (or ~pat if inverted)
        input integer n;
        input         inv;
        integer j;
        begin
            got_ok = (nrd == n);
            for (j = 0; j < n; j = j + 1)
                if (got[j] !== (inv ? ~pat[j] : pat[j])) got_ok = 0;
        end
    endfunction

    // SCL watchers
    integer  scl_edges = 0;
    always @(negedge scl) scl_edges = scl_edges + 1;
    realtime t_rise = 0;
    real     min_period;
    reg      seen_rise = 0;
    task clear_timing; begin min_period = 1e15; seen_rise = 0; end endtask
    always @(posedge scl) begin
        if (seen_rise && ($realtime - t_rise) < min_period) min_period = $realtime - t_rise;
        t_rise = $realtime; seen_rise = 1;
    end

    reg [7:0] keep50 [0:7];
    real      diff;

    // ======================= the tests =======================
    initial begin
`ifdef DUMP
        $dumpfile("tb_system.vcd");
        $dumpvars(0, tb_system);
`endif
        seed = 11;

        $display("Test 0: power up, reset both boards");
        repeat (10) @(posedge clk_m); rst_m = 0;
        press_btnu;                                   // Board S reset button
        look;
        check(scl === 1'b1 && sda === 1'b1,          "bus idle: SCL and SDA high (pull-ups)");
        check(led_s == 16'h0000 && display == 16'h0000, "Board S LEDs off, display 0000");
        check(dot[2] && dot[0] && !dot[3] && !dot[1], "Board S dots: SDA and SCL high, nobody addressed");

        $display("Test 1: PC stores 8 bytes, write request with SW15 OFF");
        for (k = 0; k < 8; k = k + 1) pat[k] = 8'h81 + k * 8'h11;   // 81 92 A3 B4 C5 D6 E7 F8
        pc_store(8);
        scl_edges = 0;
        pc_request(7'h50, 1'b0);
        #300_000;
        check(pending && !busy && scl_edges == 0,   "request pending, bus quiet");
        check(led_s == 16'h0000,                     "Board S untouched");

        $display("Test 2: SW15 ON -> data goes to slave 0x50");
        sw_m[15] = 1; settle_m;
        wait_done;
        look;
        check(!nack_err,                             "every byte ACKed");
        check(led_s[15:8] == 8'hF8,                  "Board S LD15-8 show last byte F8");
        check(display[15:8] == 8'hF8,                "Board S display digits 3-2 show F8");
        for (k = 0; k < 8; k = k + 1) keep50[k] = pat[k];

        $display("Test 3: read 0x50 back and verify");
        pc_transfer(7'h50, 1'b1);
        check(got_ok(8, 0),                          "PC got 81 92 A3 B4 C5 D6 E7 F8 back");
        check(verify_ok && status == 8'h00,          "Board M verify_ok, status 00");

        $display("Test 4: different data to slave 0x51");
        pat[0] = 8'hC0; pat[1] = 8'hFF; pat[2] = 8'hEE; pat[3] = 8'h42;
        pc_store(4);
        pc_transfer(7'h51, 1'b0);
        look;
        check(led_s == 16'hF842,                     "LEDs: 0x50 still F8, 0x51 shows 42");
        check(display == 16'hF842,                   "display reads F842");
        pc_transfer(7'h51, 1'b1);
        check(got_ok(4, 0) && verify_ok,             "0x51 reads back C0 FF EE 42, verified");

        $display("Test 5: Board S SW15 = force NACK on 0x50");
        sw_s[15] = 1; settle_s;
        pc_transfer(7'h50, 1'b0);
        check(nack_err && status == 8'h01,           "Board M sees NACK, status 01");
        check(led_s[15:8] == 8'hF8,                  "0x50 not changed");
        sw_s[15] = 0; settle_s;

        $display("Test 6: Board S SW13 = invert reads");
        sw_s[13] = 1; settle_s;
        pc_transfer(7'h51, 1'b1);
        check(verify_bad && mism_cnt == 4,           "verify catches all 4 bytes wrong");
        check(got_ok(4, 1),                          "PC sees the inverted bytes");
        sw_s[13] = 0; settle_s;
        pc_transfer(7'h51, 1'b1);
        check(verify_ok,                             "invert off -> verified again");

        $display("Test 7: speed set by Board M switches SW2-0");
        sw_m[2:0] = 3'd7; settle_m;                  // 400 kHz
        for (k = 0; k < 8; k = k + 1) pat[k] = $random(seed);
        pc_store(8);
        clear_timing;
        pc_transfer(7'h50, 1'b0);
        pc_transfer(7'h50, 1'b1);
        diff = min_period - 2500.0; if (diff < 0) diff = -diff;
        check(verify_ok && diff <= 10.0,             "400 kHz: verified, SCL period 2500 ns");
        $display("        measured period %.0f ns", min_period);
        for (k = 0; k < 8; k = k + 1) keep50[k] = pat[k];

        sw_m[2:0] = 3'd2; settle_m;                  // 10 kHz
        pat[0] = 8'h5A; pat[1] = 8'hA5;
        pc_store(2);
        clear_timing;
        pc_transfer(7'h51, 1'b0);
        pc_transfer(7'h51, 1'b1);
        diff = min_period - 100000.0; if (diff < 0) diff = -diff;
        check(verify_ok && diff <= 10.0,             "10 kHz: verified, SCL period 100 us");
        $display("        measured period %.0f ns", min_period);
        sw_m[2:0] = 3'd4; settle_m;                  // back to 100 kHz

        $display("Test 8: step mode (SW5 + BTNR)");
        sw_m[5] = 1; settle_m;
        pat[0] = 8'h3C;
        pc_store(1);
        scl_edges = 0;
        pc_request(7'h51, 1'b0);
        #200_000;
        check(busy && !done && scl_edges == 0,       "transfer started but frozen, no button presses");
        press_btnr; press_btnr; press_btnr; press_btnr;
        check(scl === 1'b0 && sda === 1'b0,          "4 presses = one START (both lines low)");
        sw_m[5] = 0; settle_m;
        wait_done;
        check(!nack_err && led_s[7:0] == 8'h3C,      "step mode off -> transfer finishes, 0x51 shows 3C");

        $display("Test 9: Board M debug mode (SW14, SW13/SW12 drive the pins)");
        sw_m[13] = 1; sw_m[12] = 0; sw_m[14] = 1; settle_m;
        look;
        check(scl === 1'b1 && sda === 1'b0,          "SW13 up = SCL high, SW12 down = SDA low");
        check(!dot[2] && dot[0],                     "Board S dots follow the pins");
        pc_request(7'h51, 1'b1);
        #100_000;
        check(pending && !busy,                      "protocol forced off while in debug");
        sw_m[12] = 1; settle_m;                      // SDA back up (that's a STOP on the bus)
        sw_m[14] = 0; settle_m;                      // leave debug -> pending read runs
        wait_done;
        check(got_ok(1, 0) && verify_ok,             "after debug, pending read runs and verifies");

        $display("Test 10: Board S reset keeps the stored data");
        press_btnu;
        look;
        check(led_s == 16'h0000 && display == 16'h0000, "BTNU clears LEDs and display");
        for (k = 0; k < 8; k = k + 1) pat[k] = keep50[k];
        pc_store(8);
        pc_transfer(7'h50, 1'b1);
        check(got_ok(8, 0) && verify_ok,             "0x50 still returns its 8 bytes");

        $display("");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d CHECK(S) FAILED", errors);
        $finish;
    end

    initial begin #200_000_000; $display("TIMEOUT"); $finish; end

endmodule
