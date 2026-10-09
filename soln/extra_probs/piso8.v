module piso8 (
    input        clk,
    input        rst,
    input        load,         // data_in ko register mein load karo
    input  [7:0] data_in,
    input        shift_en,     // ek bit shift karo
    output       serial_out    // current MSB
);

    reg [7:0]shift_reg;

    assign serial_out = shift_reg[7];

    always @(posedge clk) begin
        if (rst)
            shift_reg <= 8'h0;
        else if (load)
            shift_reg <= data_in;
        else if (shift_en)
            shift_reg <= {shift_reg[6:0], 1'b0}; 
    end

endmodule