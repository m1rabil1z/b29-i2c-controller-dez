module top_module (
    input clk,
    input resetn,
    input [1:0] byteena,
    input [15:0] d,
    output reg [15:0] q
);

    always @(posedge clk) begin
        case({resetn, byteena})
            3'b000, 3'b001, 3'b010, 3'b011: q <= 16'h0000;
            3'b100: q <= q;
            3'b101: begin
                q[15:8] <= q[15:8];
                q[7:0]  <= d[7:0];
            end
            3'b110: begin
                q[15:8] <= d[15:8];
                q[7:0]  <= q[7:0];
            end
            3'b111: q <= d;
        endcase
    end

endmodule