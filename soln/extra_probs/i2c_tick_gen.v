module i2c_tick_gen #(
    parameter CLK_FREQ = 100_000_000,   // board clock (Hz)
    parameter SCL_FREQ = 100_000        // I2C clock (Hz)
) (
    input  clk,
    input  rst,            // synchronous reset
    output reg tick4x,         // 4 x SCL_FREQ rate pe 1-clock pulse
    output reg tick            // SCL_FREQ rate pe 1-clock pulse
);

    reg [9:0] count;
    reg [8:0] count4x;

    always @(posedge clk) begin 
        if (rst) begin
            count <= 0;
            count4x <= 0;
            tick <= 0;
            tick4x <= 0;
        end else begin
            if (count == ((CLK_FREQ/SCL_FREQ)-1)) begin
                count <= 0;
                tick <= 1; 
            end else begin
                count <= count + 1;
                tick <= 0;
            end

            if (count4x == ((CLK_FREQ/(4*SCL_FREQ))-1)) begin
                count4x <= 0;
                tick4x <= 1; 
            end else begin
                count4x <= count4x + 1;
                tick4x <= 0;
            end
        end
    end

endmodule