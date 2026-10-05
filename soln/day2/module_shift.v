module top_module ( input clk, input d, output q );
    
    wire wire12;
    wire wire23;
    
    my_dff instance1(clk,d,wire12);
    my_dff instance2(clk,wire12,wire23);
    my_dff instance3(clk,wire23, q);
    

endmodule
