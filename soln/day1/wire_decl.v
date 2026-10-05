`default_nettype none
module top_module(
    input a,
    input b,
    input c,
    input d,
    output out,
    output out_n   ); 
	
    wire q;
    wire w;
    wire e;
    
    assign q = a&b;
    assign w = c&d;
    
    assign e = q|w;
    
    assign out = e;
    assign out_n = !e;
    
endmodule
