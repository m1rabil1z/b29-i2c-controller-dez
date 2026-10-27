// tb_uart_loop.v - uart_tx wired into uart_rx; also checks CRC-8("123456789") = F4
// iverilog -o sim/loop.out rtl/uart_rx.v rtl/uart_tx.v rtl/crc8.v sim/tb_uart_loop.v && vvp sim/loop.out
`timescale 1ns/1ps
module tb;
    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;
    reg [7:0] d; reg v = 0; wire rdy, line; wire [7:0] q; wire qv, fe;
    uart_tx utx (.clk(clk), .rst(rst), .data(d), .valid(v), .ready(rdy), .tx(line));
    uart_rx urx (.clk(clk), .rst(rst), .rx(line), .data(q), .valid(qv), .frame_err(fe));
    reg [7:0] msg [0:8]; integer i, errs = 0, got = 0;
    reg [7:0] crc; wire [7:0] crc_n; reg [7:0] cd;
    crc8_byte uc (.crc_in(crc), .d(cd), .crc_out(crc_n));
    always @(posedge clk) if (qv) begin
        if (q !== msg[got] || fe) begin errs = errs + 1; $display("bad byte %0d: %h", got, q); end
        got = got + 1;
    end
    initial begin
        for (i = 0; i < 9; i = i + 1) msg[i] = "1" + i;     // "123456789"
        crc = 0;
        for (i = 0; i < 9; i = i + 1) begin cd = msg[i]; #1; crc = crc_n; end
        $display("CRC-8(123456789) = %h (expect f4)", crc);
        repeat (5) @(posedge clk); rst = 0;
        for (i = 0; i < 9; i = i + 1) begin
            @(posedge clk); while (!rdy) @(posedge clk);
            d <= msg[i]; v <= 1; @(posedge clk); v <= 0;
        end
        @(posedge clk); while (!rdy) @(posedge clk);
        repeat (2000) @(posedge clk);
        $display("loopback: %0d bytes received, %0d errors -> %s", got, errs, (got == 9 && errs == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
