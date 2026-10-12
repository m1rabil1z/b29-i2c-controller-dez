module parity_generator_8bit (
    input [7:0] in,
    input type, // 1 for odd parity , 0 for even parity
    output reg parity_always,
    output parity_assign
);
    wire p = ^in; //gives odd parity

    assign parity_assign = type ? p : ~p;

    always @(*) begin
        if (type) begin
            parity_always = p;
        end else begin
            parity_always = ~p;
        end
    end

endmodule