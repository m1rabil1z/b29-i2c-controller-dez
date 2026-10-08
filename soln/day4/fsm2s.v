module top_module(
    input clk,
    input reset,    // Synchronous reset to OFF
    input j,
    input k,
    output out); //  

    parameter OFF=0, ON=1; 
    reg state, next_state;

    always @(posedge clk) begin
        if (reset) begin  
            state = OFF;
            out = 0;
        end else begin
            case (state)
                OFF: next_state = j ? ON : OFF;
                ON: next_state = k ? OFF : ON;
            endcase

            state = next_state;   

            case (state)
                OFF: out = 0;
                ON: out = 1;
            endcase
        end
    end

    // Output logic
    

endmodule
