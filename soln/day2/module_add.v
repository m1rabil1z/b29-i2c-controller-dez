module top_module(
    input [31:0] a,
    input [31:0] b,
    output [31:0] sum
);
    wire cout_t;
    wire cout_b;
    wire [15:0]sum_t;
    wire [15:0]sum_b;
    
    add16 instance_t(a[15:0], b[15:0], 1'b0, sum_t[15:0], cout_t);
    add16 instance_b(a[31:16], b[31:16], cout_t, sum_b[15:0], cout_b);
    
    assign sum[31:0] = {sum_b[15:0], sum_t[15:0]};
    

endmodule