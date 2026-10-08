module top_module(
    input clk,
    input reset,    // Synchronous reset
    input in,
    output disc,
    output flag,
    output err);
    
    parameter NONE = 0, D1 = 1,D2 = 2,D3 = 3,D4 = 4,D5 = 5,D6 = 6,DISC = 7, FLAG = 8, ERR = 9;
    reg [3:0] state, next_state;
    
    always @(posedge clk) begin
        if (reset) begin  
            state = NONE;
            err = 0;
            disc = 0;
            flag = 0;
        end else begin
            err = 0;
            disc = 0;
            flag = 0;
            case (state)
                NONE: next_state = in ? D1 : NONE;
                D1: next_state = in ? D2 : NONE;
                D2: next_state = in ? D3 : NONE;
                D3: next_state = in ? D4 : NONE;
                D4: next_state = in ? D5 : NONE;
                D5: next_state = in ? D6 : DISC;
                D6: next_state = in ? ERR : FLAG;
                DISC: next_state = in ? D1 : NONE;
                FLAG: next_state = in ? D1 : NONE;
                ERR: next_state = in ? ERR : NONE;
            endcase

            state = next_state;   

            case (state)
                DISC: disc = 1;
                FLAG: flag = 1;
                ERR: err = 1;
            endcase
        end
    end

endmodule
