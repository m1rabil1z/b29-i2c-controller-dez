module uart_tx #(parameter CLK_HZ = 100_000_000, parameter BAUD = 115_200) (
    input  wire       clk, rst,
    input  wire [7:0] data,
    input  wire       valid,       // take 'data' when valid && ready
    output wire       ready,
    output wire       tx           // pin A18 (to the PC)
);
    localparam BIT = CLK_HZ / BAUD;
    reg [9:0]  sh = 10'h3FF;       // {stop, data, start}, idle high
    reg [15:0] cnt  = 0;
    reg [3:0]  left = 0;           // bits still to send

    assign ready = (left == 0);
    assign tx    = sh[0];

    always @(posedge clk) begin
        if (rst) begin
            sh <= 10'h3FF; left <= 0; cnt <= 0;
        end else if (left == 0) begin
            if (valid) begin sh <= {1'b1, data, 1'b0}; left <= 10; cnt <= BIT - 1; end
        end else if (cnt != 0)
            cnt <= cnt - 1;
        else begin
            sh   <= {1'b1, sh[9:1]};
            left <= left - 1;
            cnt  <= BIT - 1;
        end
    end
endmodule