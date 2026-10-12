module ALU_4bit (
    input [3:0] A,
    input [3:0] B,
    input [1:0] select,
    output reg [3:0] ans,
    output reg c_out
);
    always @(*) begin
        c_out = 0;
        case (select)
            2'b00: {c_out, ans} = A + B;
            2'b01: {c_out, ans} = A - B;
            2'b10: ans = A & B;
            2'b11: ans = A | B;
            default: ans = 4'b0000;
        endcase
    end
endmodule