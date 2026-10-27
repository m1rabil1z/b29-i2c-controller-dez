`timescale 1ns/1ps
// debounce.v
//
// Cleans up one switch or button.
//   1. two flip-flops to bring the input into our clock domain (metastability)
//   2. a new value is only accepted after it has been stable for N clocks
//      (N = 1,000,000 = 10 ms at 100 MHz, longer than any contact bounce)
//   3. pulse = one clock high when the clean level goes 0 -> 1
//
// Use level for switches, pulse for buttons.
// In testbenches set N small (like 16), otherwise sim takes forever.
//
// Registers have start values (= what the FPGA powers up with anyway), so a
// debouncer that never gets a reset (like top_s's reset button) isn't X in sim.

module debounce #(
    parameter N = 1_000_000
)(
    input  wire clk,
    input  wire rst,
    input  wire in,
    output reg  level = 1'b0,
    output wire pulse
);

    localparam W = $clog2(N + 1);   // enough bits to count up to N

    reg [1:0]   sync    = 2'b00;
    reg [W-1:0] cnt     = 0;
    reg         level_d = 1'b0;   // level one clock ago, for the edge detect

    always @(posedge clk) begin
        if (rst) begin
            sync    <= 2'b00;
            cnt     <= 0;
            level   <= 1'b0;
            level_d <= 1'b0;
        end else begin
            sync    <= {sync[0], in};
            level_d <= level;

            if (sync[1] == level)
                cnt <= 0;                 // same as what we have, nothing to do
            else if (cnt == N - 1) begin
                level <= sync[1];         // different for N clocks in a row -> accept it
                cnt   <= 0;
            end else
                cnt <= cnt + 1'b1;        // different, keep counting (a bounce resets this)
        end
    end

    assign pulse = level & ~level_d;

endmodule
