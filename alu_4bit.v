module alu4 (
    input  [3:0] a,        // operand A
    input  [3:0] b,        // operand B
    input  [1:0] op,       // 00 add, 01 sub, 10 and, 11 or
    output [3:0]
y,        // result
    output       cout,    // carry (add) / borrow (sub)
    output       zero     // 1 jab y == 0
);

  reg [4:0] result;

  always @(*) begin
    case (op)
      2'b00:   result = {1'b0, a} + {1'b0, b};
      2'b01:   result = {1'b0, a} - {1'b0, b};
      2'b10:   result = {1'b0, a & b};
      2'b11:   result = {1'b0, a | b};
      default: result = 5'b00000;
    endcase
  end

  assign y = result[3:0];
  assign cout = result[4];
  assign zero = (y == 4'b0);

endmodule