module parity_assign (
    input  [7:0] data,
    input        odd,      // 0 = even parity, 1 = odd parity
    output       parity
);

  assign parity = (^data) ^ odd;

endmodule