`timescale 1ns/1ps
// seg7.v
//
// 4-digit hex seven-segment display driver for Basys 3.
//   - Anodes (an) and segments (seg, dp) are active low on Basys 3.
//   - Sweeps one digit every ~1 ms (~100,000 clocks at 100 MHz).

module seg7 #(
    parameter TICKS_PER_DIGIT = 100_000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] val,      // {digit3, digit2, digit1, digit0}
    input  wire [3:0]  dots,     // 1 = light decimal point for {DP3, DP2, DP1, DP0}
    output reg  [3:0]  an,       // active low anode enables
    output reg  [6:0]  seg,      // active low segments {g, f, e, d, c, b, a}
    output reg         dp        // active low decimal point
);

    localparam W = $clog2(TICKS_PER_DIGIT + 1);

    reg [W-1:0] cnt;
    reg [1:0]   sel;

    always @(posedge clk) begin
        if (rst) begin
            cnt <= 0;
            sel <= 2'd0;
        end else if (cnt == TICKS_PER_DIGIT - 1) begin
            cnt <= 0;
            sel <= sel + 2'd1;
        end else begin
            cnt <= cnt + 1'b1;
        end
    end

    reg [3:0] nib;

    always @(*) begin
        case (sel)
            2'd0: begin an = 4'b1110; nib = val[3:0];   dp = ~dots[0]; end
            2'd1: begin an = 4'b1101; nib = val[7:4];   dp = ~dots[1]; end
            2'd2: begin an = 4'b1011; nib = val[11:8];  dp = ~dots[2]; end
            2'd3: begin an = 4'b0111; nib = val[15:12]; dp = ~dots[3]; end
        endcase
    end

    // active-low 7-segment hex decoder: {g, f, e, d, c, b, a}
    always @(*) begin
        case (nib)
            4'h0: seg = 7'b100_0000;
            4'h1: seg = 7'b111_1001;
            4'h2: seg = 7'b010_0100;
            4'h3: seg = 7'b011_0000;
            4'h4: seg = 7'b001_1001;
            4'h5: seg = 7'b001_0010;
            4'h6: seg = 7'b000_0010;
            4'h7: seg = 7'b111_1000;
            4'h8: seg = 7'b000_0000;
            4'h9: seg = 7'b001_0000;
            4'hA: seg = 7'b000_1000;
            4'hB: seg = 7'b000_0011;
            4'hC: seg = 7'b100_0110;
            4'hD: seg = 7'b010_0001;
            4'hE: seg = 7'b000_0110;
            4'hF: seg = 7'b000_1110;
        endcase
    end

endmodule