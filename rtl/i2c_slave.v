`timescale 1ns/1ps

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

    // START / STOP detection
    wire start_det = scl_f & sda_fall;
    wire stop_det  = scl_f & sda_rise;

    // ---------- 2. Registers & Memory ----------
    reg [7:0] mem [0:239];
    reg [7:0] ptr;
    reg [7:0] count;

    integer i;
    initial begin
        for (i = 0; i < 240; i = i + 1)
            mem[i] = 8'h00;
    end

    function [7:0] get_rd_byte;
        input [7:0] p;
        reg   [7:0] raw;
        begin
            raw = (p < 8'hF0)  ? mem[p] :
                  (p == 8'hF0) ? WHO    :
                  (p == 8'hF1) ? sw_in  :
                  (p == 8'hF2) ? count  : 8'h00;
            get_rd_byte = invert ? ~raw : raw;
        end
    endfunction

    // ---------- 3. State Machine ----------
    localparam S_IDLE   = 3'd0;
    localparam S_ADDR   = 3'd1;
    localparam S_REG    = 3'd2;
    localparam S_RX     = 3'd3;
    localparam S_TX     = 3'd4;
    localparam S_IGNORE = 3'd5;

    reg [2:0] state;
    reg [3:0] bit_cnt;
    reg [7:0] shreg;
    reg       rw_bit;
    reg       m_nack;

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
            state     <= S_ADDR;
            bit_cnt   <= 4'd0;
            sda_low   <= 1'b0;
            addressed <= 1'b0;
        end else if (stop_det) begin
            state     <= S_IDLE;
            sda_low   <= 1'b0;
            addressed <= 1'b0;
        end else begin

            // RISING EDGE: Sample SDA
            if (scl_rise) begin
                case (state)
                    S_ADDR, S_REG, S_RX: begin
                        shreg   <= {shreg[6:0], sda_f};
                        bit_cnt <= bit_cnt + 4'd1;
                    end
                    S_TX: begin
                        bit_cnt <= bit_cnt + 4'd1;
                        if (bit_cnt == 4'd8)
                            m_nack <= sda_f; // sample Master ACK/NACK
                    end
                    default: ;
                endcase
            end

            // FALLING EDGE: Drive SDA & Transitions
            else if (scl_fall) begin
                case (state)

                S_ADDR: begin
                    if (bit_cnt == 4'd8) begin
                        // 8 bits received; check address
                        if ((shreg[7:1] == ADDR) && !force_nack) begin
                            sda_low   <= 1'b1; // ACK
                            addressed <= 1'b1;
                            rw_bit    <= shreg[0];
                        end else begin
                            sda_low   <= 1'b0;
                            addressed <= 1'b0;
                            state     <= S_IGNORE;
                        end
                    end else if (bit_cnt == 4'd9) begin
                        // ACK bit finished
                        bit_cnt <= 4'd0;
                        if (rw_bit) begin
                            state   <= S_TX;
                            shreg   <= get_rd_byte(ptr);
                            sda_low <= ~get_rd_byte_msb(ptr); // Drive bit 7
                        end else begin
                            state   <= S_REG;
                            sda_low <= 1'b0;
                        end
                    end
                end

                S_REG: begin
                    if (bit_cnt == 4'd8) begin
                        if (!force_nack) begin
                            ptr     <= shreg;
                            sda_low <= 1'b1; // ACK
                        end else begin
                            sda_low <= 1'b0;
                            state   <= S_IGNORE;
                        end
                    end else if (bit_cnt == 4'd9) begin
                        bit_cnt <= 4'd0;
                        sda_low <= 1'b0;
                        state   <= S_RX;
                    end
                end

                S_RX: begin
                    if (bit_cnt == 4'd8) begin
                        if (!force_nack) begin
                            if (ptr < 8'hF0)
                                mem[ptr] <= shreg;
                            last_byte <= shreg;
                            count     <= count + 8'd1;
                            ptr       <= ptr + 8'd1;
                            sda_low   <= 1'b1; // ACK
                        end else begin
                            sda_low <= 1'b0;
                            state   <= S_IGNORE;
                        end
                    end else if (bit_cnt == 4'd9) begin
                        bit_cnt <= 4'd0;
                        sda_low <= 1'b0;
                    end
                end

                S_TX: begin
                    if (bit_cnt < 4'd8) begin
                        sda_low <= ~shreg[7 - bit_cnt]; // drive bits 6..0
                    end else if (bit_cnt == 4'd8) begin
                        sda_low <= 1'b0; // release for Master ACK/NACK
                    end else if (bit_cnt == 4'd9) begin
                        bit_cnt <= 4'd0;
                        if (!m_nack) begin
                            // Master ACK: advance pointer and drive next MSB
                            ptr     <= ptr + 8'd1;
                            shreg   <= get_rd_byte(ptr + 8'd1);
                            sda_low <= ~get_rd_byte_msb(ptr + 8'd1);
                        end else begin
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

    function get_rd_byte_msb;
        input [7:0] p;
        reg   [7:0] b;
        begin
            b = get_rd_byte(p);
            get_rd_byte_msb = b[7];
        end
    endfunction

endmodule