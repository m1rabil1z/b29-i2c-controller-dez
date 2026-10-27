`timescale 1ns/1ps
// tb_full.v
//
// The complete system, end to end, nothing forced:
//   PC packets over UART -> top_m (uart_bridge + i2c_seq + i2c_master)
//   -> pulled-up I2C bus -> top_s (two i2c_slave) -> replies back over UART.
// Each board on its own clock. Reply bytes are checked exactly, CRC included.
//
// Run:
//   iverilog -o sim/tb_full.out rtl/debounce.v rtl/mode_ctrl.v rtl/i2c_seq.v rtl/i2c_master.v rtl/uart_rx.v rtl/uart_tx.v rtl/crc8.v rtl/uart_bridge.v rtl/seg7.v rtl/top_m.v rtl/i2c_slave.v rtl/top_s.v sim/tb_full.v
//   vvp sim/tb_full.out

module tb_full;

    reg clk_m = 0;  always #5 clk_m = ~clk_m;
    reg clk_s = 0;  initial begin #3; forever #5.001 clk_s = ~clk_s; end

    tri1 scl, sda;                                   // pull-ups

    // ---------- Board M ----------
    reg        btnU_m = 0, btnR_m = 0;
    reg [15:0] sw_m   = 16'h0004;                    // 100 kHz, protocol OFF
    wire [15:0] led_m;  wire [6:0] seg_m;  wire dp_m;  wire [3:0] an_m;
    wire        to_m, from_m;

    top_m #(.DEB_N(16), .TICKS_PER_DIGIT(20)) u_m (
        .clk(clk_m), .btnU(btnU_m), .btnR(btnR_m), .sw(sw_m),
        .led(led_m), .seg(seg_m), .dp(dp_m), .an(an_m),
        .RsRx(to_m), .RsTx(from_m), .scl_pin(scl), .sda_pin(sda)
    );

    // ---------- Board S ----------
    reg        btnU_s = 0;
    reg [15:0] sw_s   = 16'h0000;
    wire [15:0] led_s;  wire [6:0] seg_s;  wire dp_s;  wire [3:0] an_s;

    top_s #(.DEB_N(16)) u_s (
        .clk(clk_s), .btnU(btnU_s), .sw(sw_s),
        .led(led_s), .seg(seg_s), .dp(dp_s), .an(an_s),
        .scl_pin(scl), .sda_pin(sda)
    );

    // ---------- the PC ----------
    reg  [7:0] pc_d = 0;
    reg        pc_v = 0;
    wire       pc_rdy, pc_rv;
    wire [7:0] pc_rd;
    uart_tx pc_tx (.clk(clk_m), .rst(1'b0), .data(pc_d), .valid(pc_v), .ready(pc_rdy), .tx(to_m));
    uart_rx pc_rx (.clk(clk_m), .rst(1'b0), .rx(from_m), .data(pc_rd), .valid(pc_rv), .frame_err());

    reg [7:0] rep [0:63];
    integer   nrep = 0;
    always @(posedge clk_m) if (pc_rv) begin rep[nrep] = pc_rd; nrep = nrep + 1; end

    function [7:0] crc_step;           // CRC-8 poly 0x07, one byte
        input [7:0] c, d;
        integer j;
        begin
            crc_step = c ^ d;
            for (j = 0; j < 8; j = j + 1)
                crc_step = crc_step[7] ? ((crc_step << 1) ^ 8'h07) : (crc_step << 1);
        end
    endfunction

    task send_byte;
        input [7:0] b;
        begin
            @(posedge clk_m); while (!pc_rdy) @(posedge clk_m);
            pc_d <= b; pc_v <= 1; @(posedge clk_m); pc_v <= 0; @(posedge clk_m);
        end
    endtask

    reg [7:0] dbuf [0:31];             // DATA of the next request
    reg [7:0] crc;
    integer   k;

    task send_packet;                  // A5 CMD DEV REG LEN DATA CRC
        input [7:0] cmd, dev;
        input integer len;
        begin
            nrep = 0;
            crc = 0;
            send_byte(8'hA5);
            send_byte(cmd);  crc = crc_step(crc, cmd);
            send_byte(dev);  crc = crc_step(crc, dev);
            send_byte(8'h00); crc = crc_step(crc, 8'h00);
            send_byte(len[7:0]); crc = crc_step(crc, len[7:0]);
            for (k = 0; k < len; k = k + 1) begin send_byte(dbuf[k]); crc = crc_step(crc, dbuf[k]); end
            send_byte(crc);
        end
    endtask

    // wait for a complete reply 5A ST LEN DATA CRC (or give up after max_us)
    reg [7:0] r_st, r_len;
    reg       r_ok;
    task get_reply;
        input integer max_us;
        integer t;
        begin
            r_ok = 0; t = 0;
            while (t < max_us && !(nrep >= 3 && nrep >= rep[2] + 4)) begin #1000; t = t + 1; end
            if (nrep >= 3 && nrep >= rep[2] + 4) begin
                r_st = rep[1]; r_len = rep[2];
                crc = crc_step(crc_step(8'h00, r_st), r_len);
                for (k = 0; k < r_len; k = k + 1) crc = crc_step(crc, rep[3 + k]);
                r_ok = (rep[0] == 8'h5A) && (rep[3 + r_len] == crc);
            end
        end
    endtask

    // ---------- checks ----------
    integer errors = 0;
    task check;
        input cond;
        input [8*64-1:0] msg;
        begin
            if (cond) $display("  PASS  %0s", msg);
            else begin $display("  FAIL  %0s", msg); errors = errors + 1; end
        end
    endtask
    task settle_m; repeat (40) @(posedge clk_m); endtask
    task settle_s; repeat (40) @(posedge clk_s); endtask

    initial begin
        $display("Test 0: reset both boards");
        btnU_m = 1; btnU_s = 1; settle_m; btnU_m = 0; btnU_s = 0; settle_m; settle_s;
        check(scl === 1'b1 && sda === 1'b1, "bus idle high");

        $display("Test 1: ECHO AB CD (link only)");
        dbuf[0] = 8'hAB; dbuf[1] = 8'hCD;
        send_packet(8'h04, 8'h00, 2); get_reply(5000);
        check(r_ok && nrep == 6 && rep[1] == 8'h00 && rep[3] == 8'hAB && rep[4] == 8'hCD && rep[5] == 8'h34,
              "reply 5A 00 02 AB CD 34");

        $display("Test 2: CLEAR, STORE 11 22 33");
        send_packet(8'h07, 8'h00, 0); get_reply(5000);
        check(r_ok && r_st == 8'h00, "CLEAR -> OK");
        dbuf[0] = 8'h11; dbuf[1] = 8'h22; dbuf[2] = 8'h33;
        send_packet(8'h05, 8'h00, 3); get_reply(5000);
        check(r_ok && r_st == 8'h00 && u_m.u_seq.count == 3, "STORE -> OK, 3 bytes in Board M");

        $display("Test 3: SEND_STORED to 0x50, protocol OFF then ON");
        send_packet(8'h06, 8'h50, 0); get_reply(3000);
        check(!r_ok && nrep == 0 && led_s[15:8] == 8'h00, "no reply and Board S untouched while SW15 off");
        sw_m[15] = 1; settle_m;
        get_reply(20000);
        check(r_ok && r_st == 8'h00, "SW15 on -> transfer runs, reply OK");
        repeat (300) @(posedge clk_s);
        check(led_s[15:8] == 8'h33, "Board S LD15-8 show 33");

        $display("Test 4: READ_VERIFY from 0x50");
        send_packet(8'h09, 8'h50, 0); get_reply(20000);
        check(r_ok && nrep == 7 && rep[1] == 8'h00 && rep[3] == 8'h11 && rep[4] == 8'h22 && rep[5] == 8'h33 && rep[6] == 8'hEE,
              "reply 5A 00 03 11 22 33 EE (exact)");
        check(led_m[8] && !led_m[9], "Board M LD8 verify OK");

        $display("Test 5: corrupt a byte inside slave 0x50");
        u_s.u_slave1.mem[1] = 8'hFF;
        send_packet(8'h09, 8'h50, 0); get_reply(20000);
        check(r_ok && rep[1] == 8'h08 && rep[4] == 8'hFF && rep[6] == 8'hA4,
              "reply 5A 08 03 11 FF 33 A4 (exact)");
        check(led_m[9], "Board M LD9 verify bad");

        $display("Test 6: SEND_STORED to 0x42 (nobody there)");
        send_packet(8'h06, 8'h42, 0); get_reply(20000);
        check(r_ok && nrep == 4 && rep[1] == 8'h02 && rep[3] == 8'h2A, "reply 5A 02 00 2A (exact)");
        check(scl === 1'b1 && sda === 1'b1, "bus released");

        $display("Test 7: Board S SW15 forces NACK on 0x50");
        sw_s[15] = 1; settle_s;
        send_packet(8'h06, 8'h50, 0); get_reply(20000);
        check(r_ok && r_st == 8'h02, "NACK reported to the PC");
        sw_s[15] = 0; settle_s;

        $display("Test 8: 32-byte block to 0x51 and back");
        send_packet(8'h07, 8'h00, 0); get_reply(5000);
        for (k = 0; k < 32; k = k + 1) dbuf[k] = 8'hC0 ^ k[7:0];
        send_packet(8'h05, 8'h00, 32); get_reply(5000);
        check(r_ok && r_st == 8'h00, "STORE 32 bytes -> OK");
        send_packet(8'h06, 8'h51, 0); get_reply(50000);
        check(r_ok && r_st == 8'h00, "SEND_STORED to 0x51 -> OK");
        send_packet(8'h09, 8'h51, 0); get_reply(50000);
        r_ok = r_ok && (r_st == 8'h00) && (r_len == 32);
        for (k = 0; k < 32; k = k + 1) if (rep[3 + k] !== (8'hC0 ^ k[7:0])) r_ok = 0;
        check(r_ok, "READ_VERIFY returns all 32 bytes, status OK");

        $display("Test 9: corrupted request");
        dbuf[0] = 8'h11; dbuf[1] = 8'h22;
        nrep = 0; crc = 0;
        send_byte(8'hA5); send_byte(8'h04); send_byte(8'h00); send_byte(8'h00); send_byte(8'h02);
        send_byte(8'h11); send_byte(8'h22); send_byte(8'h00);      // wrong CRC
        get_reply(5000);
        check(r_ok && r_st == 8'h01, "BAD_CRC reported");

        $display("");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d CHECK(S) FAILED", errors);
        $finish;
    end

    initial begin #300_000_000; $display("TIMEOUT"); $finish; end

endmodule
