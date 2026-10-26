module uart_rx #(parameter CLK_HZ = 100_000_000, parameter BAUD = 115_200) (
    input  wire       clk, rst,
    input  wire       rx,          // pin B18 (from the PC)
    output reg  [7:0] data,
    output reg        valid,       // one clock when a byte is in
    output reg        frame_err    // stop bit was 0
);
    localparam BIT = CLK_HZ / BAUD;            // 868 clocks per bit
    reg [1:0]  sync = 2'b11;                   // idle line is high
    reg [15:0] cnt  = 0;
    reg [3:0]  bitn;
    reg        busy = 1'b0;                    // start value = FPGA power-up
    wire       r = sync[1];

    always @(posedge clk) begin
        sync  <= {sync[0], rx};
        valid <= 1'b0;
        if (rst) begin
            busy <= 0; cnt <= 0; bitn <= 0; frame_err <= 0; data <= 0;
        end else if (!busy) begin
            if (!r) begin busy <= 1; cnt <= BIT / 2; bitn <= 0; end   // start bit: go to its middle
        end else if (cnt != 0)
            cnt <= cnt - 1;
        else begin
            cnt <= BIT - 1;                                            // next bit centre
            if (bitn == 0) begin
                if (r) busy <= 0;                                      // false start (glitch)
            end else if (bitn <= 8)
                data <= {r, data[7:1]};                                // LSB first
            else begin
                busy <= 0; valid <= 1; frame_err <= !r;                // stop bit
            end
            bitn <= bitn + 1;
        end
    end
endmodule