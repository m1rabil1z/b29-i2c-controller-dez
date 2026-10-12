module piso8 (
    input        clk,
    input        rst,
    input        load,         // data_in ko register mein load karo
    input  [7:0] data_in,
    input        shift_en,     // ek bit shift karo
    output       serial_out    // current MSB
);

  reg [7:0] shift_reg;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      shift_reg <= 8'b0;
    end else if (load) begin
      shift_reg <= data_in;
    end else if (shift_en) begin
      shift_reg <= {shift_reg[6:0], 1'b0};
    end
  end

  assign serial_out = shift_reg[7];

endmodule