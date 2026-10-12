module sipo8 (
    input        clk,
    input        rst,
    input        shift_en,     // serial_in ko andar shift karo
    input        serial_in,
    output reg [7:0]
data_out
);

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      data_out <= 8'b0;
    end else if (shift_en) begin
      data_out <= {data_out[6:0], serial_in};
    end
  end

endmodule