`timescale 1ns/1ps
// tb_i2c_seq.v
//
// The whole Board M data path in simulation:
//   PC stores bytes -> PC asks for a write -> protocol switch ON -> bytes go
//   to the slave -> PC asks for a read -> bytes come back -> compared.
// Uses i2c_seq + i2c_master + two model slaves (0x50, 0x51) at 100 kHz.
// Run:
//   iverilog -o sim/tb_seq.out rtl/i2c_seq.v rtl/i2c_master.v sim/i2c_slave_model.v sim/tb_i2c_seq.v
//   vvp sim/tb_seq.out

module tb_i2c_seq;

    reg clk = 0;
    always #5 clk = ~clk;            // 100 MHz

    reg rst = 1;

    // ---------- PC side (what Abhirup's packet parser will drive) ----------
    reg        store_valid = 0;
    reg  [7:0] store_byte  = 0;
    reg        clear       = 0;
    reg        req_valid   = 0;
    reg  [6:0] req_addr    = 0;
    reg        req_rw      = 0;
    reg        run_en      = 0;      // SW15

    wire       rd_valid, done, pending, busy;
    wire [7:0] rd_byte, status, count, last_stored, last_read, mism_cnt;
    wire       verify_ok, verify_bad, nack_err, empty_err;

    // ---------- sequencer <-> master ----------
    wire       m_cmd_valid, m_cmd_ready, m_rsp_valid, m_rsp_nack;
    wire [2:0] m_cmd;
    wire [7:0] m_cmd_data, m_rsp_data;

    // ---------- bus ----------
    wire m_scl_low, m_sda_low, s0_scl_low, s0_sda_low, s1_scl_low, s1_sda_low;
    wire scl = ~(m_scl_low | s0_scl_low | s1_scl_low);
    wire sda = ~(m_sda_low | s0_sda_low | s1_sda_low);

    i2c_seq #(.DEPTH(32)) u_seq (
        .clk(clk), .rst(rst),
        .store_valid(store_valid), .store_byte(store_byte), .clear(clear),
        .req_valid(req_valid), .req_addr(req_addr), .req_rw(req_rw),
        .run_en(run_en),
        .m_cmd_valid(m_cmd_valid), .m_cmd_ready(m_cmd_ready), .m_cmd(m_cmd), .m_cmd_data(m_cmd_data),
        .m_rsp_valid(m_rsp_valid), .m_rsp_data(m_rsp_data), .m_rsp_nack(m_rsp_nack),
        .rd_valid(rd_valid), .rd_byte(rd_byte), .done(done), .status(status),
        .count(count), .pending(pending), .busy(busy),
        .last_stored(last_stored), .last_read(last_read),
        .verify_ok(verify_ok), .verify_bad(verify_bad),
        .nack_err(nack_err), .empty_err(empty_err), .mism_cnt(mism_cnt)
    );

    i2c_master u_master (
        .clk(clk), .rst(rst),
        .cmd_valid(m_cmd_valid), .cmd_ready(m_cmd_ready), .cmd(m_cmd), .cmd_data(m_cmd_data),
        .rsp_valid(m_rsp_valid), .rsp_data(m_rsp_data), .rsp_nack(m_rsp_nack),
        .t_low(25'd500), .t_high(25'd498), .step_mode(1'b0), .step(1'b0),   // 100 kHz
        .scl_low(m_scl_low), .sda_low(m_sda_low), .scl_in(scl), .sda_in(sda),
        .bus_busy(), .arb_lost(), .dbg_state(), .dbg_shift()
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

    // ---------- PC-side helpers ----------
    task store;                      // send one data byte to the master
        input [7:0] b;
        begin
            @(posedge clk); store_valid <= 1; store_byte <= b;
            @(posedge clk); store_valid <= 0;
        end
    endtask

    task request;                    // ask for a write (rw=0) or read (rw=1)
        input [6:0] a;
        input       r;
        begin
            @(posedge clk); req_valid <= 1; req_addr <= a; req_rw <= r;
            @(posedge clk); req_valid <= 0;
        end
    endtask

    task wait_done;
        begin
            @(posedge clk);
            while (!done) @(posedge clk);
            @(posedge clk);          // let the flags settle
        end
    endtask

    // collect every byte the sequencer reads back
    reg [7:0] got [0:31];
    integer   nrd = 0;
    always @(posedge clk) if (rd_valid) begin got[nrd] = rd_byte; nrd = nrd + 1; end

    // count SCL edges, to prove the bus stays quiet when it should
    integer scl_edges = 0;
    always @(negedge scl) scl_edges = scl_edges + 1;

    reg [7:0] tx [0:7];
    integer   k;
    reg       ok;

    initial begin
        $dumpfile("tb_i2c_seq.vcd");
        $dumpvars(0, tb_i2c_seq);

        tx[0] = 8'h11; tx[1] = 8'h22; tx[2] = 8'h33; tx[3] = 8'h44;
        tx[4] = 8'h55; tx[5] = 8'h66; tx[6] = 8'h77; tx[7] = 8'h88;

        repeat (5) @(posedge clk);
        rst <= 0;
        repeat (5) @(posedge clk);

        $display("Test 1: PC stores 8 bytes in the master");
        for (k = 0; k < 8; k = k + 1) store(tx[k]);
        repeat (2) @(posedge clk);
        check(count == 8,           "8 bytes stored");
        check(last_stored == 8'h88, "last stored byte shown (88)");

        $display("Test 2: write request with protocol OFF");
        scl_edges = 0;
        request(7'h50, 1'b0);
        #300_000;                                    // wait 300 us
        check(pending && !busy,     "request is pending, nothing running");
        check(scl_edges == 0,       "bus stayed quiet");
        check(slave0.mem[0] == 8'h00, "slave not written yet");

        $display("Test 3: protocol ON -> write runs");
        run_en = 1;
        wait_done;
        check(!nack_err && !pending, "write finished, every byte ACKed");
        ok = 1;
        for (k = 0; k < 8; k = k + 1) if (slave0.mem[k] != tx[k]) ok = 0;
        check(ok, "slave 0x50 holds 11 22 33 44 55 66 77 88");

        $display("Test 4: read back and verify");
        nrd = 0;
        request(7'h50, 1'b1);
        wait_done;
        ok = (nrd == 8);
        for (k = 0; k < 8; k = k + 1) if (got[k] != tx[k]) ok = 0;
        check(ok, "8 bytes came back, same as written");
        check(verify_ok && !verify_bad && mism_cnt == 0, "verify_ok = 1");
        check(status == 8'h00, "status byte for the PC = 00");

        $display("Test 5: corrupt one byte in the slave, read again");
        slave0.mem[3] = 8'hFF;
        nrd = 0;
        request(7'h50, 1'b1);
        wait_done;
        check(verify_bad && !verify_ok, "mismatch detected");
        check(mism_cnt == 1, "exactly one byte wrong");
        check(got[3] == 8'hFF && status == 8'h02, "PC sees FF at byte 3, status 02");

        $display("Test 6: nobody at 0x42");
        request(7'h42, 1'b0);
        wait_done;
        check(nack_err && status == 8'h01, "NACK reported, status 01");
        check(!busy && scl === 1'b1 && sda === 1'b1, "bus released (STOP sent)");

        $display("Test 7: switch OFF in the middle of a transfer");
        request(7'h51, 1'b0);
        @(posedge clk); while (!busy) @(posedge clk);
        #100_000;
        run_en = 0;                                  // protocol off mid-way
        wait_done;
        ok = 1;
        for (k = 0; k < 8; k = k + 1) if (slave1.mem[k] != tx[k]) ok = 0;
        check(ok && !nack_err, "transfer still finished cleanly to 0x51");
        run_en = 1;
        nrd = 0;
        request(7'h51, 1'b1);
        wait_done;
        check(verify_ok && nrd == 8, "0x51 read back and verified");

        $display("Test 8: read with nothing stored");
        clear <= 1; @(posedge clk); clear <= 0;
        repeat (2) @(posedge clk);
        check(count == 0, "buffer cleared");
        scl_edges = 0;
        request(7'h50, 1'b1);
        wait_done;
        check(empty_err && status == 8'h04, "empty_err, status 04");
        check(scl_edges == 0, "bus untouched");

        $display("");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d CHECK(S) FAILED", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule