module top_module(
    input clk,
    input in,
    input reset,    // Synchronous reset
    output reg done
);
    parameter NONE = 0, D1 = 1, D2 = 2, D3 = 3, D4 = 4, D5 = 5, D6 = 6, D7 = 7, D8 = 8, DONE = 9, STOP = 10, ERR = 11;
    reg [3:0] state, next_state;
    
    always @(posedge clk) begin
        if (reset) begin  
            state = NONE;
            done = 0;
        end else begin
            done = 0;
            case (state)
                NONE: next_state = in ? NONE : D1;
                D1: next_state = D2;
                D2: next_state = D3;
                D3: next_state = D4;
                D4: next_state = D5;
                D5: next_state = D6;
                D6: next_state = D7;
                D7: next_state = D8;
                D8: next_state = STOP;
                STOP: next_state = in ? DONE : ERR;
                ERR: next_state = in ? NONE : ERR;
                DONE: next_state = in ? NONE : D1; 
            endcase

            state = next_state;   

            case (state)
                DONE: done = 1;
            endcase
        end
    end

endmodule
