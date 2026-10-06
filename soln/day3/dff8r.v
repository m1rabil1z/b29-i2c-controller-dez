module top_module (
    input clk,
    input reset,            // Synchronous reset
    input [7:0] d,
    output [7:0] q
);
    always @(posedge clk) begin
        case(reset)
            1'b0: q[7:0] = d[7:0];
            1'b1: q[7:0] = 8'h0;
        endcase       
    end

endmodule