module top_module ( 
    input clk, 
    input [7:0] d, 
    input [1:0] sel, 
    output [7:0] q 
);
    wire [7:0] wire12;
    wire [7:0]wire23;
    wire [7:0]wire3m;
    
    my_dff8 instance1(clk, d[7:0], wire12[7:0] );
    my_dff8 instance2(clk, wire12[7:0], wire23[7:0]);
    my_dff8 instance3(clk, wire23[7:0], wire3m[7:0]);
    
    always @(*) begin
        case (sel)
            2'b00: q[7:0] = d[7:0];
            2'b01: q[7:0] = wire12[7:0];
            2'b10: q[7:0] = wire23[7:0];
            2'b11: q[7:0] = wire3m[7:0];
        endcase
    end

endmodule