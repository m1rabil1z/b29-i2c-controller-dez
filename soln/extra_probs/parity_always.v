module parity_always (
    input [7:0] data,
    input odd,      // 0 = even parity, 1 = odd parity
    output reg parity
);

    always @(*) begin
        if (odd)
            parity = ^data ? 0 : 1;
        else
            parity = ^data ? 1 : 0;
    end

endmodule