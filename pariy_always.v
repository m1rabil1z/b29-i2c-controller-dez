module parity_always (
    input  [7:0] data,
    input        odd,
    output reg   parity
);

  always @(*) begin
    parity = (^data) ^ odd;
  end

endmodule