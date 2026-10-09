module parity_assign (
    input  [7:0] data,
    input        odd,
    output       parity
);

    assign parity = ^data ^ odd;

endmodule