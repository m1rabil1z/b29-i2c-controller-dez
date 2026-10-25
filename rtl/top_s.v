`timescale 1ns/1ps
// top_s.v
//
// Board S top level: two I2C slaves (0x50 and 0x51) on shared bus pins.
//
//   SW7-SW0     sw_in, readable at register 0xF1
//   SW13        invert for both slaves
//   SW15 / SW14 force_nack for slave 1 (0x50) / slave 2 (0x51)
//   BTNU        synchronous reset (debounced)
//   LD15-LD8    last_byte of slave 1 (0x50)
//   LD7-LD0     last_byte of slave 2 (0x51)
//   Digits 3-2  slave 1 last_byte in hex
//   Digits 1-0  slave 2 last_byte in hex
//   DP3 / DP1   slave 1 / slave 2 addressed
//   DP2 / DP0   SDA / SCL level as Board S sees it

module top_s #(
    parameter DEB_N = 1_000_000
)(
    input  wire        clk,
    input  wire        btnU,      // reset button
    input  wire [15:0] sw,
    output wire [15:0] led,
    output wire [6:0]  seg,
    output wire        dp,
    output wire [3:0]  an,
    input  wire        scl_pin,   // input only: slave never drives SCL
    inout  wire        sda_pin    // open-drain shared SDA
);

    // debounce reset button (rst_in tied to 0 so debounce itself can run)
    wire rst;
    debounce #(.N(DEB_N)) u_db_rst (
        .clk(clk), .rst(1'b0), .in(btnU),
        .level(rst), .pulse()
    );

    // debounce switches used by the slaves
    wire [7:0] sw_in_lvl;
    wire       invert_lvl;
    wire       nack1_lvl, nack2_lvl;

    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : g_sw
            debounce #(.N(DEB_N)) u_db_sw (
                .clk(clk), .rst(rst), .in(sw[g]),
                .level(sw_in_lvl[g]), .pulse()
            );
        end
    endgenerate

    debounce #(.N(DEB_N)) u_db_inv (
        .clk(clk), .rst(rst), .in(sw[13]), .level(invert_lvl), .pulse()
    );
    debounce #(.N(DEB_N)) u_db_nack1 (
        .clk(clk), .rst(rst), .in(sw[15]), .level(nack1_lvl), .pulse()
    );
    debounce #(.N(DEB_N)) u_db_nack2 (
        .clk(clk), .rst(rst), .in(sw[14]), .level(nack2_lvl), .pulse()
    );

    // two I2C slaves sharing scl_pin and sda_pin
    wire       s1_sda_low, s2_sda_low;
    wire [7:0] s1_last_byte, s2_last_byte;
    wire       s1_addressed, s2_addressed;

    i2c_slave #(
        .ADDR(7'h50),
        .WHO (8'hC1)
    ) u_slave1 (
        .clk       (clk),
        .rst       (rst),
        .scl_in    (scl_pin),
        .sda_in    (sda_pin),
        .sda_low   (s1_sda_low),
        .force_nack(nack1_lvl),
        .invert    (invert_lvl),
        .sw_in     (sw_in_lvl),
        .last_byte (s1_last_byte),
        .addressed (s1_addressed)
    );

    i2c_slave #(
        .ADDR(7'h51),
        .WHO (8'hC2)
    ) u_slave2 (
        .clk       (clk),
        .rst       (rst),
        .scl_in    (scl_pin),
        .sda_in    (sda_pin),
        .sda_low   (s2_sda_low),
        .force_nack(nack2_lvl),
        .invert    (invert_lvl),
        .sw_in     (sw_in_lvl),
        .last_byte (s2_last_byte),
        .addressed (s2_addressed)
    );

    // open-drain wired-AND on SDA
    assign sda_pin = (s1_sda_low | s2_sda_low) ? 1'b0 : 1'bz;

    // LEDs and 7-segment display
    assign led = {s1_last_byte, s2_last_byte};

    // synchronize raw bus pins just for clean display dots DP2 (SDA) and DP0 (SCL)
    reg [1:0] scl_disp_sync, sda_disp_sync;
    always @(posedge clk) begin
        scl_disp_sync <= {scl_disp_sync[0], scl_pin};
        sda_disp_sync <= {sda_disp_sync[0], sda_pin};
    end

    wire [3:0] dots = {s1_addressed, sda_disp_sync[1], s2_addressed, scl_disp_sync[1]};

    seg7 u_seg7 (
        .clk (clk),
        .rst (rst),
        .val ({s1_last_byte, s2_last_byte}),
        .dots(dots),
        .an  (an),
        .seg (seg),
        .dp  (dp)
    );

endmodule