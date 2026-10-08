module top_module(
    input clk,
    input in,
    input reset,    // Synchronous reset
    output [7:0] out_byte,
    output done
); //

    // Modify FSM and datapath from Fsm_serialdata
    parameter NONE = 0, D1 = 1, D2 = 2, D3 = 3, D4 = 4, D5 = 5, D6 = 6, D7 = 7, D8 = 8, DONE = 9, STOP = 10, ERR = 11, PAR = 12;
    reg [3:0] state, next_state;
    wire parityc;
    wire parity_reset;
    
    assign parity_reset = reset | (state == DONE) | (state == ERR) | (state == NONE);
    
    parity instance1(clk, parity_reset, in, parityc);
    
    always @(posedge clk) begin
        if (reset) begin  
            state = NONE;
            done = 0;
        end else begin
            done = 0;
            case (state)
                NONE: next_state = in ? NONE : D1;
                D1: begin 
                    next_state = D2;
                    out_byte[0] = in;
                end
                D2: begin 
                    next_state = D3;
                    out_byte[1] = in;
                end
                D3: begin 
                    next_state = D4;
                    out_byte[2] = in;
                end
                D4: begin 
                    next_state = D5;
                    out_byte[3] = in;
                end
                D5: begin 
                    next_state = D6;
                    out_byte[4] = in;
                end
                D6: begin 
                    next_state = D7;
                    out_byte[5] = in;
                end
                D7: begin 
                    next_state = D8;
                    out_byte[6] = in;
                end
                D8: begin 
                    next_state = PAR;
                    out_byte[7] = in;
                end
                PAR: next_state = STOP; 
                STOP: next_state = in ? (parityc ? DONE : NONE) : ERR;
                ERR: next_state = in ? NONE : ERR;
                DONE: next_state = in ? NONE : D1; 
            endcase

            state = next_state;   

            case (state)
                DONE: done = 1;
            endcase
        end
    end

    // New: Add parity checking.

endmodule
