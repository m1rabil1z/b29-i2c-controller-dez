module i2c_tick_gen #(
    parameter CLK_FREQ = 100_000_000,   // board clock (Hz)
    parameter SCL_FREQ = 100_000        // I2C clock (Hz)
) (
    input  clk,
    input  rst,            // synchronous reset
    output tick4x,         // 4 x SCL_FREQ rate pe 1-clock pulse
    output tick            // SCL_FREQ rate pe 1-clock pulse
);

parameter COUNT_4X = CLK_FREQ / (SCL_FREQ * 4);

reg [31:0] clk_cnt = 0;
reg [1:0]  sub_cnt = 0;

always @(posedge clk) begin
    if(rst) begin
        clk_cnt <= 0; 
        sub_cnt <= 0;
    end
    else if (clk_cnt == COUNT_4X - 1) begin
        clk_cnt <= 0;
        sub_cnt <= sub_cnt + 1;
    end    
    else begin
        clk_cnt <= clk_cnt + 1'b1;
    end 

end

assign tick4x = (clk_cnt == COUNT_4X - 1);
assign tick   = tick4x && (sub_cnt == 2'd3);

endmodule