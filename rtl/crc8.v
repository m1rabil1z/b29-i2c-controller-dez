// CRC-8, poly 0x07, init 0x00 (SMBus). One byte per call.
module crc8_byte (input wire [7:0] crc_in, input wire [7:0] d, output wire [7:0] crc_out);
    function [7:0] step;
        input [7:0] c;
        integer i;
        begin
            step = c;
            for (i = 0; i < 8; i = i + 1)
                step = step[7] ? ((step << 1) ^ 8'h07) : (step << 1);
        end
    endfunction
    assign crc_out = step(crc_in ^ d);
endmodule
