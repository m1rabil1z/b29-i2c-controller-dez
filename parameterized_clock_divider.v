module clock_divider #(
    parameter DIVISOR = 4 // dividing factor (parameterized)
)(
    input clk, // input_clk
    input areset, // asynchronous reset
    output reg clk_out // frequency divided clk
);

    reg [31:0] counter = 0;

    always @(posedge clk or posedge areset) begin
        if (areset) begin
            counter <= 0;
            clk_out <= 0;
        end 
        else if (counter == (DIVISOR / 2 - 1)) begin
            counter <= 0;
            clk_out <= ~clk_out;
        end 
        else begin
            counter <= counter + 1;
        end
    end

endmodule