`timescale 1ns/1ps
// tb_store_readback.v
//
// Stress test: can the real slaves store data and give it back on command?
// i2c_seq (PC side) -> i2c_master -> Neer's two real i2c_slave (0x50, 0x51).
//
//   1  32-byte block to 0x50, read back, verify
//   2  different block to 0x51; 0x50 still reads back its own data
//   3  read 0x50 twice -> same data both times (reading doesn't change it)
//   4  overwrite 0x50 with new data, read back the new data
//   5  whole slave memory: 240 bytes to 0x51 and back
//   6  16-byte write + read back at 10 kHz, 100 kHz, 400 kHz
//   7  slave display outputs: last_byte = last byte written, addressed drops after STOP
//
// RISE = rise time of SCL/SDA in ns (falls are instant), to mimic weak pull-ups:
//   iverilog -o sim/tb_srb.out rtl/i2c_seq.v rtl/i2c_master.v rtl/i2c_slave.v sim/tb_store_readback.v
//   vvp sim/tb_srb.out
//   (slow edges: add  -P tb_store_readback.RISE=1000  to the iverilog line)

module tb_store_readback;

    parameter RISE = 0;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    // ---------- PC side ----------
    reg        store_valid = 0, clear = 0, req_valid = 0, req_rw = 0, run_en = 1;
    reg  [7:0] store_byte = 0;
    reg  [6:0] req_addr = 0;
    wire       rd_valid, done, pending, busy, verify_ok, verify_bad, nack_err, empty_err;
    wire [7:0] rd_byte, status, count, last_stored, last_read, mism_cnt;

    // ---------- seq <-> master ----------
    wire       m_cmd_valid, m_cmd_ready, m_rsp_valid, m_rsp_nack;
    wire [2:0] m_cmd;
    wire [7:0] m_cmd_data, m_rsp_data;
    reg [24:0] t_low = 25'd500, t_high = 25'd498;      // 100 kHz to start

    // ---------- bus with optional slow rising edges ----------
    wire m_scl_low, m_sda_low, s0_sda_low, s1_sda_low;
    wire #(RISE, 0) scl = ~m_scl_low;
    wire #(RISE, 0) sda = ~(m_sda_low | s0_sda_low | s1_sda_low);

    wire [7:0] s0_last, s1_last;
    wire       s0_addr, s1_addr;

    i2c_seq #(.DEPTH(240)) u_seq (
        .clk(clk), .rst(rst),
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
        .clk(clk), .rst(rst),
        .cmd_valid(m_cmd_valid), .cmd_ready(m_cmd_ready), .cmd(m_cmd), .cmd_data(m_cmd_data),
        .rsp_valid(m_rsp_valid), .rsp_data(m_rsp_data), .rsp_nack(m_rsp_nack),
        .t_low(t_low), .t_high(t_high), .step_mode(1'b0), .step(1'b0),
        .scl_low(m_scl_low), .sda_low(m_sda_low), .scl_in(scl), .sda_in(sda),
        .bus_busy(), .arb_lost(), .dbg_state(), .dbg_shift()
    );

    i2c_slave #(.ADDR(7'h50), .WHO(8'hC1)) slave0 (
        .clk(clk), .rst(rst), .scl_in(scl), .sda_in(sda), .sda_low(s0_sda_low),
        .force_nack(1'b0), .invert(1'b0), .sw_in(8'h00), .last_byte(s0_last), .addressed(s0_addr));
    i2c_slave #(.ADDR(7'h51), .WHO(8'hC2)) slave1 (
        .clk(clk), .rst(rst), .scl_in(scl), .sda_in(sda), .sda_low(s1_sda_low),
        .force_nack(1'b0), .invert(1'b0), .sw_in(8'h00), .last_byte(s1_last), .addressed(s1_addr));

    // ---------- helpers ----------
    integer errors = 0;
    task check;
        input cond;
        input [8*64-1:0] msg;
        begin
            if (cond) $display("  PASS  %0s", msg);
            else begin $display("  FAIL  %0s", msg); errors = errors + 1; end
        end
    endtask

    reg [7:0] pat [0:239];    // the data we send
    reg [7:0] got [0:239];    // what came back
    integer   nrd = 0;
    always @(posedge clk) if (rd_valid) begin got[nrd] = rd_byte; nrd = nrd + 1; end

    integer k, seed;

    // fill pat[0..n-1]: kind 0 = counting, 1 = random
    task make_pattern;
        input integer n;
        input integer kind;
        begin
            for (k = 0; k < n; k = k + 1)
                pat[k] = (kind == 0) ? k[7:0] : $random(seed);
        end
    endtask

    // clear the master's buffer and store pat[0..n-1]
    task store_block;
        input integer n;
        begin
            @(posedge clk); clear <= 1; @(posedge clk); clear <= 0;
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk); store_valid <= 1; store_byte <= pat[k];
            end
            @(posedge clk); store_valid <= 0;
            @(posedge clk);
        end
    endtask

    task transfer;            // one write (rw=0) or read (rw=1), wait till done
        input [6:0] a;
        input       r;
        begin
            nrd = 0;
            @(posedge clk); req_valid <= 1; req_addr <= a; req_rw <= r;
            @(posedge clk); req_valid <= 0;
            @(posedge clk); while (!done) @(posedge clk);
            @(posedge clk);
        end
    endtask

    function slave_holds;     // does slave memory match pat[0..n-1]?
        input integer which;
        input integer n;
        integer j;
        begin
            slave_holds = 1;
            for (j = 0; j < n; j = j + 1)
                if (which == 0 ? (slave0.mem[j] !== pat[j]) : (slave1.mem[j] !== pat[j]))
                    slave_holds = 0;
        end
    endfunction

    function got_matches;     // did the read return pat[0..n-1]?
        input integer n;
        integer j;
        begin
            got_matches = (nrd == n);
            for (j = 0; j < n; j = j + 1) if (got[j] !== pat[j]) got_matches = 0;
        end
    endfunction

    // write a block, read it back, check all three views of it
    task write_read_check;
        input [6:0] a;
        input integer which;
        input integer n;
        begin
            store_block(n);
            transfer(a, 1'b0);
            check(!nack_err && slave_holds(which, n), "slave stored every byte");
            transfer(a, 1'b1);
            check(got_matches(n), "every byte came back to the master");
            check(verify_ok && mism_cnt == 0, "hardware verify_ok");
        end
    endtask

    reg [7:0] keep0 [0:31];

    initial begin
        seed = 7;
        $display("Bus rise time: %0d ns", RISE);
        repeat (5) @(posedge clk); rst <= 0; repeat (5) @(posedge clk);

        $display("Test 1: 32-byte block to 0x50");
        make_pattern(32, 1);
        write_read_check(7'h50, 0, 32);
        for (k = 0; k < 32; k = k + 1) keep0[k] = pat[k];

        $display("Test 2: different block to 0x51, 0x50 keeps its own");
        make_pattern(32, 0);
        write_read_check(7'h51, 1, 32);
        for (k = 0; k < 32; k = k + 1) pat[k] = keep0[k];
        store_block(32);                     // so the sequencer compares against 0x50's data
        transfer(7'h50, 1'b1);
        check(got_matches(32) && verify_ok, "0x50 still returns its own 32 bytes");

        $display("Test 3: reading twice gives the same data");
        transfer(7'h50, 1'b1);
        check(got_matches(32) && verify_ok, "second read identical");

        $display("Test 4: overwrite 0x50 with new data");
        make_pattern(32, 1);
        write_read_check(7'h50, 0, 32);

        $display("Test 5: whole slave memory, 240 bytes to 0x51");
        make_pattern(240, 1);
        write_read_check(7'h51, 1, 240);

        $display("Test 6: 16 bytes at 10 kHz, 100 kHz, 400 kHz");
        make_pattern(16, 1);
        t_low = 25'd5000; t_high = 25'd4998;  $display("  10 kHz");
        write_read_check(7'h50, 0, 16);
        make_pattern(16, 1);
        t_low = 25'd500;  t_high = 25'd498;   $display("  100 kHz");
        write_read_check(7'h51, 1, 16);
        make_pattern(16, 1);
        t_low = 25'd150;  t_high = 25'd98;    $display("  400 kHz");
        write_read_check(7'h50, 0, 16);
        t_low = 25'd500;  t_high = 25'd498;

        $display("Test 7: slave display outputs");
        make_pattern(4, 1);
        store_block(4);
        transfer(7'h51, 1'b0);
        check(s1_last == pat[3], "0x51 last_byte = last byte written (LEDs)");
        check(!s0_addr && !s1_addr, "addressed drops after STOP");

        $display("");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d CHECK(S) FAILED", errors);
        $finish;
    end

    initial begin #400_000_000; $display("TIMEOUT"); $finish; end

endmodule
