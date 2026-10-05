module top_module(
    input [31:0] a,
    input [31:0] b,
    output [31:0] sum
);
    wire cout_t;
    wire cout_b0;
    wire cout_b1;
    wire [15:0]sum_t;
    wire [15:0]sum_b0;
    wire [15:0]sum_b1;
    
    add16 instance_t(a[15:0], b[15:0], 1'b0, sum_t[15:0], cout_t);
    add16 instance_b0(a[31:16], b[31:16], 1'b0, sum_b0[15:0], cout_b0);
    add16 instance_b1(a[31:16], b[31:16], 1'b1, sum_b1[15:0], cout_b1);
    
    assign sum[15:0] = sum_t[15:0];
    
    always @(*) begin
        case (cout_t)
            1'b0: sum[31:16] = sum_b0[15:0];
            1'b1: sum[31:16] = sum_b1[15:0];
        endcase
    end

endmodule