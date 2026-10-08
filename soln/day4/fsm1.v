module top_module(
    input clk,
    input areset,    // Asynchronous reset to state B
    input in,
    output out);//  

    parameter A=0, B=1; 
    reg state, next_state;

    always @(*) begin
        case(state)
            A: next_state = in ? A : B;
            B: next_state = in ? B : A;
        endcase
        // This is a combinational always block
        // State transition logic
    end

    always @(posedge clk, posedge areset) begin
        if (areset)
            state = B;
        else
            state = next_state;
        // This is a sequential always block
        // State flip-flops with asynchronous reset
    end
            
    assign out = state;

    // Output logic
    // assign out = (state == ...);

endmodule
