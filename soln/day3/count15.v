module top_module (
    input clk,
    input reset,      // Synchronous active-high reset
    output [3:0] q);

    always @(posedge clk) begin
        if (reset)
            q = 4'h0;
        else begin
            case(q)
                4'h0: q = 4'h1;
                4'h1: q = 4'h2;
                4'h2: q = 4'h3;
                4'h3: q = 4'h4;
                4'h4: q = 4'h5;
                4'h5: q = 4'h6;
                4'h6: q = 4'h7;
                4'h7: q = 4'h8;
                4'h8: q = 4'h9;
                4'h9: q = 4'ha;
                4'ha: q = 4'hb;
                4'hb: q = 4'hc;
                4'hc: q = 4'hd;
                4'hd: q = 4'he;
                4'he: q = 4'hf;
                4'hf: q = 4'h0;
            endcase
        end
    end
    
endmodule