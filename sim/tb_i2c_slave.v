`timescale 1ns/1ps
// tb_i2c_slave.v
//
// Ring 1 self-checking testbench for i2c_slave.v.
// Bit-bangs SCL and SDA at 100 kHz (Q = 2500 ns) and verifies all 8 checks.

module tb_i2c_slave;

    reg clk = 0;
    always #5 clk = ~clk;   // 100 MHz (10 ns period)

    reg        rst        = 1;
    reg        m_scl_low  = 0;
    reg        m_sda_low  = 0;
    reg        force_nack = 0;
    reg        invert     = 0;
    reg  [7:0] sw_in      = 8'hA5;

    wire       s_sda_low;
    wire [7:0] last_byte;
    wire       addressed;

    wire scl = ~m_scl_low;                    // slave never drives SCL
    wire sda = ~(m_sda_low | s_sda_low);      // wired-AND with pull-up

    localparam Q = 2500;                      // quarter of a 100 kHz bit (ns)

    i2c_slave #(
        .ADDR(7'h50),
        .WHO (8'hC1)
    ) dut (
        .clk       (clk),
        .rst       (rst),
        .scl_in    (scl),
        .sda_in    (sda),
        .sda_low   (s_sda_low),
        .force_nack(force_nack),
        .invert    (invert),
        .sw_in     (sw_in),
        .last_byte (last_byte),
        .addressed (addressed)
    );

    // ---------- bit-bang tasks ----------
    task bb_start;
        begin
            m_sda_low = 1; #Q;
            m_scl_low = 1; #Q;
        end
    endtask

    task bb_stop;
        begin
            m_sda_low = 1; #Q;
            m_scl_low = 0; #Q;
            m_sda_low = 0; #Q;
        end
    endtask

    task bb_restart;
        begin
            m_sda_low = 0; #Q;
            m_scl_low = 0; #Q;
            bb_start;
        end
    endtask

    task bb_bit;
        input  b;
        output r;
        begin
            m_sda_low = ~b; #Q;
            m_scl_low = 0;  #Q;
            r = sda;        #Q;
            m_scl_low = 1;  #Q;
        end
    endtask

    task bb_write_byte;
        input  [7:0] data;
        output       ack;   // 1 = ACKed (SDA pulled low), 0 = NACKed
        integer k;
        reg     r;
        begin
            for (k = 7; k >= 0; k = k - 1)
                bb_bit(data[k], r);
            bb_bit(1'b1, r);
            ack = (r == 1'b0);
        end
    endtask

    task bb_read_byte;
        input        send_ack;   // 1 = master ACKs, 0 = master NACKs
        output [7:0] data;
        integer k;
        reg     r;
        begin
            for (k = 7; k >= 0; k = k - 1) begin
                bb_bit(1'b1, r);
                data[k] = r;
            end
            bb_bit(~send_ack, r);
        end
    endtask

    // ---------- check helper ----------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check;
        input         cond;
        input [255:0] msg;
        begin
            if (cond) begin
                $display("  [PASS] %0s", msg);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  [FAIL] %0s (time %0t)", msg, $time);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ---------- main test sequence ----------
    reg       ack;
    reg [7:0] rdata0, rdata1, rdata2;
    integer   k;
    reg       dummy;

    initial begin
        $dumpfile("tb_i2c_slave.vcd");
        $dumpvars(0, tb_i2c_slave);

        #100;
        rst = 0;
        #100;

        // 1. 0x50 + W is ACKed; 0x42 + W is not
        bb_start;
        bb_write_byte({7'h50, 1'b0}, ack);
        check(ack == 1'b1 && addressed == 1'b1, "1a: 0x50+W ACKed and addressed=1");
        bb_stop;

        bb_start;
        bb_write_byte({7'h42, 1'b0}, ack);
        check(ack == 1'b0 && addressed == 1'b0, "1b: 0x42+W NACKed and addressed=0");
        bb_stop;

        // 2. Write 3 bytes at register 0x10, then read them back through repeated START
        bb_start;
        bb_write_byte({7'h50, 1'b0}, ack);
        bb_write_byte(8'h10, ack);
        bb_write_byte(8'hDE, ack);
        bb_write_byte(8'hAD, ack);
        bb_write_byte(8'hBE, ack);
        check(last_byte == 8'hBE, "2a: last_byte updated to 0xBE");
        bb_stop;

        bb_start;
        bb_write_byte({7'h50, 1'b0}, ack);
        bb_write_byte(8'h10, ack);
        bb_restart;
        bb_write_byte({7'h50, 1'b1}, ack);
        bb_read_byte(1'b1, rdata0);   // ACK
        bb_read_byte(1'b1, rdata1);   // ACK
        bb_read_byte(1'b0, rdata2);   // NACK last byte
        check(s_sda_low == 1'b0, "8: SDA released after master NACKs last read byte");
        bb_stop;
        check(rdata0 == 8'hDE && rdata1 == 8'hAD && rdata2 == 8'hBE,
              "2b: Read back 3 bytes (DE, AD, BE) via repeated START");

        // 3. 0xF0 reads 0xC1; 0xF1 reads sw_in (0xA5); 0xF2 counts bytes written (3)
        bb_start;
        bb_write_byte({7'h50, 1'b0}, ack);
        bb_write_byte(8'hF0, ack);
        bb_restart;
        bb_write_byte({7'h50, 1'b1}, ack);
        bb_read_byte(1'b1, rdata0);
        bb_read_byte(1'b1, rdata1);
        bb_read_byte(1'b0, rdata2);
        bb_stop;
        check(rdata0 == 8'hC1, "3a: Register 0xF0 (WHO_AM_I) reads 0xC1");
        check(rdata1 == 8'hA5, "3b: Register 0xF1 (sw_in) reads 0xA5");
        check(rdata2 == 8'd3,  "3c: Register 0xF2 (count) reads 3");

        // 4. invert = 1 returns inverted data
        invert = 1'b1;
        bb_start;
        bb_write_byte({7'h50, 1'b0}, ack);
        bb_write_byte(8'hF0, ack);
        bb_restart;
        bb_write_byte({7'h50, 1'b1}, ack);
        bb_read_byte(1'b0, rdata0);
        bb_stop;
        invert = 1'b0;
        check(rdata0 == ~8'hC1, "4: invert=1 returns ~0xC1 (0x3E)");

        // 5. force_nack = 1 refuses the address
        force_nack = 1'b1;
        bb_start;
        bb_write_byte({7'h50, 1'b0}, ack);
        bb_stop;
        force_nack = 1'b0;
        check(ack == 1'b0, "5: force_nack=1 NACKs matching address");

        // 6. A 20 ns spike on SCL is ignored by the glitch filter
        bb_start;
        // send 4 bits normally, inject a 20 ns high glitch while SCL is low, then finish
        for (k = 7; k >= 4; k = k - 1)
            bb_bit((k == 6 || k == 4), dummy); // bits 7..4 of 8'hA0 (0x50+W) = 4'b1010
        // SCL is currently low; pulse it high for 20 ns (2 clocks < 4-clock filter)
        #500;
        m_scl_low = 0; #20; m_scl_low = 1;
        #500;
        for (k = 3; k >= 0; k = k - 1)
            bb_bit(1'b0, dummy);
        bb_bit(1'b1, dummy);
        ack = (dummy == 1'b0);
        bb_stop;
        check(ack == 1'b1, "6: 20 ns spike on SCL ignored by glitch filter");

        // 7. A START in the middle of a byte restarts address reception
        bb_start;
        // send only 4 bits of a byte
        for (k = 0; k < 4; k = k + 1)
            bb_bit(1'b1, dummy);
        // issue a fresh START mid-byte and address 0x50+W
        bb_restart;
        bb_write_byte({7'h50, 1'b0}, ack);
        bb_stop;
        check(ack == 1'b1, "7: START mid-byte cleanly restarts address reception");

        $display("\n========================================");
        $display("  Ring 1 Summary: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $display("========================================\n");
        $finish;
    end

endmodule