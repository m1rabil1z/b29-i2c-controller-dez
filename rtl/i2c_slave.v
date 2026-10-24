`timescale 1ns/1ps
// i2c_slave.v
//
// Synthesizable I2C slave for Board S.
//   1. 2-flop synchronizer + 4-clock glitch filter (40 ns at 100 MHz) on SCL/SDA
//   2. Samples SDA on scl_rise, changes sda_low on scl_fall
//   3. Never stretches SCL (no scl_low output)
//   4. Register map:
//        0x00-0xEF : 240-byte read/write memory (mem), pointer auto-increments
//        0xF0      : WHO_AM_I (read-only parameter WHO)
//        0xF1      : sw_in    (read-only Board S switches SW7-SW0)
//        0xF2      : count    (read-only count of data bytes written)

module i2c_slave #(
    parameter [6:0] ADDR = 7'h50,
    parameter [7:0] WHO  = 8'hC1
)(
    input  wire       clk,
    input  wire       rst,

    // bus lines
    input  wire       scl_in,
    input  wire       sda_in,
    output reg        sda_low,

    // switches / config
    input  wire       force_nack,
    input  wire       invert,
    input  wire [7:0] sw_in,

    // outputs to board
    output reg  [7:0] last_byte,
    output reg        addressed
);

    // ---------- 1. Input conditioning ----------
    // 2-flop sync + 4-sample glitch filter. Bus idles high, so reset to 1.
    reg [1:0] scl_sync;
    reg [1:0] scl_cnt;
    reg       scl_f, scl_f_d;

    always @(posedge clk) begin
        if (rst) begin
            scl_sync <= 2'b11;
            scl_cnt  <= 2'd0;
            scl_f    <= 1'b1;
            scl_f_d  <= 1'b1;
        end else begin
            scl_sync <= {scl_sync[0], scl_in};
            scl_f_d  <= scl_f;
            if (scl_sync[1] == scl_f)
                scl_cnt <= 2'd0;
            else if (scl_cnt == 2'd3) begin
                scl_f   <= scl_sync[1];
                scl_cnt <= 2'd0;
            end else
                scl_cnt <= scl_cnt + 2'd1;
        end
    end

    wire scl_rise =  scl_f & ~scl_f_d;
    wire scl_fall = ~scl_f &  scl_f_d;

    reg [1:0] sda_sync;
    reg [1:0] sda_cnt;
    reg       sda_f, sda_f_d;

    always @(posedge clk) begin
        if (rst) begin
            sda_sync <= 2'b11;
            sda_cnt  <= 2'd0;
            sda_f    <= 1'b1;
            sda_f_d  <= 1'b1;
        end else begin
            sda_sync <= {sda_sync[0], sda_in};
            sda_f_d  <= sda_f;
            if (sda_sync[1] == sda_f)
                sda_cnt <= 2'd0;
            else if (sda_cnt == 2'd3) begin
                sda_f   <= sda_sync[1];
                sda_cnt <= 2'd0;
            end else
                sda_cnt <= sda_cnt + 2'd1;
        end
    end

    wire sda_rise =  sda_f & ~sda_f_d;
    wire sda_fall = ~sda_f &  sda_f_d;

    // START and STOP happen while SCL is high
    wire start_det = scl_f & sda_fall;
    wire stop_det  = scl_f & sda_rise;

    // ---------- 2. Registers & Memory ----------
    reg [7:0] mem [0:239];   // named 'mem' so tb_i2c_master can inspect slave0.mem[...]
    reg [7:0] ptr;
    reg [7:0] count;

    integer i;
    initial begin
        for (i = 0; i < 240; i = i + 1)
            mem[i] = 8'h00;
    end

    wire [7:0] rd_raw = (ptr < 8'hF0)  ? mem[ptr] :
                        (ptr == 8'hF0) ? WHO      :
                        (ptr == 8'hF1) ? sw_in    :
                        (ptr == 8'hF2) ? count    : 8'h00;

    wire [7:0] rd_byte = invert ? ~rd_raw : rd_raw;

    // ---------- 3. State Machine ----------
    localparam S_IDLE   = 3'd0;
    localparam S_ADDR   = 3'd1;
    localparam S_REG    = 3'd2;
    localparam S_RX     = 3'd3;
    localparam S_TX     = 3'd4;
    localparam S_IGNORE = 3'd5;

    reg [2:0] state;
    reg [3:0] bit_cnt;   // 0-7 data bits, 8 = ACK bit
    reg [7:0] shreg;
    reg       rw_bit;    // 0 = write, 1 = read
    reg       m_nack;    // master's ACK/NACK response during TX

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            bit_cnt   <= 4'd0;
            shreg     <= 8'd0;
            rw_bit    <= 1'b0;
            m_nack    <= 1'b1;
            ptr       <= 8'd0;
            count     <= 8'd0;
            last_byte <= 8'd0;
            sda_low   <= 1'b0;
            addressed <= 1'b0;
        end else if (start_det) begin
            // START or repeated START from any state
            state     <= S_ADDR;
            bit_cnt   <= 4'd0;
            sda_low   <= 1'b0;
            addressed <= 1'b0;
        end else if (stop_det) begin
            state     <= S_IDLE;
            sda_low   <= 1'b0;
            addressed <= 1'b0;
        end else begin

            // sample SDA on SCL rising edge
            if (scl_rise) begin
                case (state)
                    S_ADDR, S_REG, S_RX: begin
                        if (bit_cnt < 4'd8)
                            shreg <= {shreg[6:0], sda_f};
                    end
                    S_TX: begin
                        if (bit_cnt == 4'd8)
                            m_nack <= sda_f;   // 0 = master ACKed, 1 = master NACKed
                    end
                    default: ;
                endcase
            end

            // drive SDA and transition states on SCL falling edge
            else if (scl_fall) begin
                case (state)

                S_ADDR: begin
                    if (bit_cnt == 4'd7) begin
                        // 8th bit just finished; check address and drive ACK
                        bit_cnt <= 4'd8;
                        if (shreg[7:1] == ADDR && !force_nack) begin
                            sda_low   <= 1'b1;
                            addressed <= 1'b1;
                            rw_bit    <= shreg[0];
                            if (shreg[0])
                                ptr <= (ptr == 8'hEF) ? 8'h00 : ptr; // keep ptr ready for read
                        end else begin
                            sda_low   <= 1'b0;
                            addressed <= 1'b0;
                            state     <= S_IGNORE;
                        end
                    end else if (bit_cnt == 4'd8) begin
                        // end of address ACK clock
                        bit_cnt <= 4'd0;
                        if (rw_bit) begin
                            state   <= S_TX;
                            shreg   <= rd_byte;
                            sda_low <= ~rd_byte[7]; // put MSB on SDA immediately
                        end else begin
                            state   <= S_REG;
                            sda_low <= 1'b0;
                        end
                    end else begin
                        bit_cnt <= bit_cnt + 4'd1;
                    end
                end

                S_REG: begin
                    if (bit_cnt == 4'd7) begin
                        bit_cnt <= 4'd8;
                        if (!force_nack) begin
                            ptr     <= shreg;
                            sda_low <= 1'b1;        // ACK the register byte
                        end else begin
                            sda_low <= 1'b0;
                            state   <= S_IGNORE;
                        end
                    end else if (bit_cnt == 4'd8) begin
                        bit_cnt <= 4'd0;
                        sda_low <= 1'b0;
                        state   <= S_RX;
                    end else begin
                        bit_cnt <= bit_cnt + 4'd1;
                    end
                end

                S_RX: begin
                    if (bit_cnt == 4'd7) begin
                        bit_cnt <= 4'd8;
                        if (!force_nack) begin
                            if (ptr < 8'hF0)
                                mem[ptr] <= shreg;
                            last_byte <= shreg;
                            count     <= count + 8'd1;
                            ptr       <= ptr + 8'd1;
                            sda_low   <= 1'b1;      // ACK the data byte
                        end else begin
                            sda_low   <= 1'b0;
                            state     <= S_IGNORE;
                        end
                    end else if (bit_cnt == 4'd8) begin
                        bit_cnt <= 4'd0;
                        sda_low <= 1'b0;            // release SDA for next byte or STOP
                    end else begin
                        bit_cnt <= bit_cnt + 4'd1;
                    end
                end

                S_TX: begin
                    if (bit_cnt < 4'd7) begin
                        // shift out bits 6 down to 0
                        bit_cnt <= bit_cnt + 4'd1;
                        shreg   <= {shreg[6:0], 1'b0};
                        sda_low <= ~shreg[6];
                    end else if (bit_cnt == 4'd7) begin
                        // finished sending bit 0; release SDA so master can ACK/NACK
                        bit_cnt <= 4'd8;
                        sda_low <= 1'b0;
                    end else begin
                        // end of 9th clock (master ACK/NACK)
                        bit_cnt <= 4'd0;
                        if (!m_nack) begin
                            // master ACKed: advance pointer and drive MSB of next byte
                            // Note: rd_byte uses ptr, so compute next byte from ptr + 1
                            ptr     <= ptr + 8'd1;
                            shreg   <= next_rd_byte(ptr + 8'd1);
                            sda_low <= ~next_rd_byte_msb(ptr + 8'd1);
                        end else begin
                            // master NACKed: release SDA and wait for STOP / repeated START
                            sda_low <= 1'b0;
                            state   <= S_IGNORE;
                        end
                    end
                end

                S_IGNORE: begin
                    sda_low <= 1'b0;
                end

                default: begin
                    sda_low <= 1'b0;
                    state   <= S_IDLE;
                end
                endcase
            end
        end
    end

    // helper functions to fetch the next read byte on the same clock ptr increments
    function [7:0] next_rd_byte;
        input [7:0] p;
        reg   [7:0] raw;
        begin
            raw = (p < 8'hF0)  ? mem[p] :
                  (p == 8'hF0) ? WHO    :
                  (p == 8'hF1) ? sw_in  :
                  (p == 8'hF2) ? count  : 8'h00;
            next_rd_byte = invert ? ~raw : raw;
        end
    endfunction

    function next_rd_byte_msb;
        input [7:0] p;
        reg   [7:0] b;
        begin
            b = next_rd_byte(p);
            next_rd_byte_msb = b[7];
        end
    endfunction

endmodule