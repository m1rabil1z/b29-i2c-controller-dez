module sipo8 (
    input        clk,
    input        rst,
    input        shift_en,     // serial_in ko andar shift karo
    input        serial_in,
    output reg [7:0] data_out
);

    always @(posedge clk) begin
        if (rst)
            data_out <= 8'h0;
        else if (shift_en)
            data_out <= {data_out[6:0], serial_in};
    end
    
endmodule