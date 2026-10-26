`timescale 1ns/1ps

module uart_bridge (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    output reg  [7:0]  tx_data,
    output reg         tx_valid,
    input  wire        tx_ready,
    output reg         store_valid,
    output reg  [7:0]  store_byte,
    output reg         clear,
    output reg         req_valid,
    output reg  [6:0]  req_addr,
    output reg         req_rw,
    input  wire [7:0]  count,
    input  wire        busy,
    input  wire        pending,
    input  wire        rd_valid,
    input  wire [7:0]  rd_byte,
    input  wire        done,
    input  wire [7:0]  status
);

    localparam S_WAIT_SYNC  = 4'd0;
    localparam S_CMD        = 4'd1;
    localparam S_DEV        = 4'd2;
    localparam S_REG        = 4'd3;
    localparam S_LEN        = 4'd4;
    localparam S_DATA       = 4'd5;
    localparam S_CRC        = 4'd6;
    localparam S_CHECK      = 4'd7;
    localparam S_EXEC       = 4'd8;
    localparam S_STORE_WR   = 4'd9;
    localparam S_WAIT_DONE  = 4'd10;
    localparam S_REPLY_INIT = 4'd11;
    localparam S_REPLY_TX   = 4'd12;

    reg [3:0]  state;
    reg [7:0]  cmd_reg;
    reg [7:0]  dev_reg;
    reg [7:0]  reg_reg;
    reg [7:0]  len_reg;
    reg [7:0]  rx_crc;
    reg [7:0]  crc_reg;
    reg [7:0]  in_buf [0:31];
    reg [7:0]  reply_buf [0:31];
    reg [7:0]  bytes_rcvd;
    reg [7:0]  store_idx;
    reg [7:0]  rd_cnt;
    reg [19:0] timeout_cnt;

    reg [7:0]  rep_status;
    reg [7:0]  rep_len;
    reg [2:0]  tx_phase;
    reg [7:0]  tx_idx;
    reg [7:0]  tx_crc;

    wire [7:0] parse_crc_in = (state == S_CMD) ? 8'h00 : crc_reg;
    wire [7:0] parse_crc_out;

    crc8_byte u_crc_parse (
        .crc_in(parse_crc_in),
        .d(rx_data),
        .crc_out(parse_crc_out)
    );

    reg  [7:0] tx_crc_in;
    reg  [7:0] tx_crc_d;
    wire [7:0] tx_crc_out;

    crc8_byte u_crc_tx (
        .crc_in(tx_crc_in),
        .d(tx_crc_d),
        .crc_out(tx_crc_out)
    );

    integer i;

    always @(*) begin
        case (tx_phase)
            3'd1: begin
                tx_crc_in = 8'h00;
                tx_crc_d  = rep_status;
            end
            3'd2: begin
                tx_crc_in = tx_crc;
                tx_crc_d  = rep_len;
            end
            3'd3: begin
                tx_crc_in = tx_crc;
                tx_crc_d  = reply_buf[tx_idx];
            end
            default: begin
                tx_crc_in = 8'h00;
                tx_crc_d  = 8'h00;
            end
        endcase
    end

    always @(posedge clk) begin
        store_valid <= 1'b0;
        clear       <= 1'b0;
        req_valid   <= 1'b0;

        if (rst) begin
            state       <= S_WAIT_SYNC;
            cmd_reg     <= 8'h00;
            dev_reg     <= 8'h00;
            reg_reg     <= 8'h00;
            len_reg     <= 8'h00;
            rx_crc      <= 8'h00;
            crc_reg     <= 8'h00;
            bytes_rcvd  <= 8'h00;
            store_idx   <= 8'h00;
            rd_cnt      <= 8'h00;
            timeout_cnt <= 20'd0;
            rep_status  <= 8'h00;
            rep_len     <= 8'h00;
            tx_phase    <= 3'd0;
            tx_idx      <= 8'h00;
            tx_crc      <= 8'h00;
            tx_data     <= 8'h00;
            tx_valid    <= 1'b0;
            store_byte  <= 8'h00;
            req_addr    <= 7'h00;
            req_rw      <= 1'b0;
        end else begin

            if (state >= S_CMD && state <= S_CRC) begin
                if (rx_valid)
                    timeout_cnt <= 20'd0;
                else if (timeout_cnt == 20'd999_999) begin
                    rep_status <= 8'h05;
                    rep_len    <= 8'h00;
                    state      <= S_REPLY_INIT;
                end else
                    timeout_cnt <= timeout_cnt + 20'd1;
            end else begin
                timeout_cnt <= 20'd0;
            end

            case (state)

            S_WAIT_SYNC: begin
                if (rx_valid && rx_data == 8'hA5) begin
                    state      <= S_CMD;
                    crc_reg    <= 8'h00;
                    bytes_rcvd <= 8'h00;
                end
            end

            S_CMD: begin
                if (rx_valid) begin
                    cmd_reg <= rx_data;
                    crc_reg <= parse_crc_out;
                    state   <= S_DEV;
                end
            end

            S_DEV: begin
                if (rx_valid) begin
                    dev_reg <= rx_data;
                    crc_reg <= parse_crc_out;
                    state   <= S_REG;
                end
            end

            S_REG: begin
                if (rx_valid) begin
                    reg_reg <= rx_data;
                    crc_reg <= parse_crc_out;
                    state   <= S_LEN;
                end
            end

            S_LEN: begin
                if (rx_valid) begin
                    len_reg    <= rx_data;
                    crc_reg    <= parse_crc_out;
                    bytes_rcvd <= 8'h00;
                    if (rx_data == 8'h00)
                        state <= S_CRC;
                    else
                        state <= S_DATA;
                end
            end

            S_DATA: begin
                if (rx_valid) begin
                    if (bytes_rcvd < 8'd32)
                        in_buf[bytes_rcvd] <= rx_data;
                    crc_reg    <= parse_crc_out;
                    bytes_rcvd <= bytes_rcvd + 8'd1;
                    if (bytes_rcvd + 8'd1 == len_reg)
                        state <= S_CRC;
                end
            end

            S_CRC: begin
                if (rx_valid) begin
                    rx_crc <= rx_data;
                    state  <= S_CHECK;
                end
            end

            S_CHECK: begin
                if (rx_crc != crc_reg) begin
                    rep_status <= 8'h01;
                    rep_len    <= 8'h00;
                    state      <= S_REPLY_INIT;
                end else begin
                    state <= S_EXEC;
                end
            end

            S_EXEC: begin
                if (cmd_reg == 8'h04) begin
                    rep_status <= 8'h00;
                    rep_len    <= len_reg;
                    for (i = 0; i < 32; i = i + 1)
                        reply_buf[i] <= in_buf[i];
                    state <= S_REPLY_INIT;
                end else if (cmd_reg == 8'h07) begin
                    if (!busy && !pending) begin
                        clear      <= 1'b1;
                        rep_status <= 8'h00;
                        rep_len    <= 8'h00;
                        state      <= S_REPLY_INIT;
                    end
                end else if (cmd_reg == 8'h05) begin
                    if (len_reg == 8'h00 || len_reg > 8'd32 || (count + len_reg > 8'd32)) begin
                        rep_status <= 8'h07;
                        rep_len    <= 8'h00;
                        state      <= S_REPLY_INIT;
                    end else begin
                        store_idx <= 8'h00;
                        state     <= S_STORE_WR;
                    end
                end else if (cmd_reg == 8'h06) begin
                    if (!busy && !pending) begin
                        req_valid <= 1'b1;
                        req_addr  <= dev_reg[6:0];
                        req_rw    <= 1'b0;
                        state     <= S_WAIT_DONE;
                    end
                end else if (cmd_reg == 8'h09) begin
                    if (!busy && !pending) begin
                        rd_cnt    <= 8'h00;
                        req_valid <= 1'b1;
                        req_addr  <= dev_reg[6:0];
                        req_rw    <= 1'b1;
                        state     <= S_WAIT_DONE;
                    end
                end else begin
                    rep_status <= 8'h04;
                    rep_len    <= 8'h00;
                    state      <= S_REPLY_INIT;
                end
            end

            S_STORE_WR: begin
                if (!busy && !pending) begin
                    if (store_idx < len_reg) begin
                        store_valid <= 1'b1;
                        store_byte  <= in_buf[store_idx];
                        store_idx   <= store_idx + 8'd1;
                    end else begin
                        rep_status <= 8'h00;
                        rep_len    <= 8'h00;
                        state      <= S_REPLY_INIT;
                    end
                end
            end

            S_WAIT_DONE: begin
                if (rd_valid) begin
                    reply_buf[rd_cnt] <= rd_byte;
                    rd_cnt            <= rd_cnt + 8'd1;
                end
                if (done) begin
                    if (status[0])
                        rep_status <= 8'h02;
                    else if (status[2])
                        rep_status <= 8'h09;
                    else if (status[1])
                        rep_status <= 8'h08;
                    else
                        rep_status <= 8'h00;

                    if (cmd_reg == 8'h09)
                        rep_len <= rd_valid ? (rd_cnt + 8'd1) : rd_cnt;
                    else
                        rep_len <= 8'h00;

                    state <= S_REPLY_INIT;
                end
            end

            S_REPLY_INIT: begin
                tx_phase <= 3'd0;
                tx_idx   <= 8'h00;
                tx_valid <= 1'b0;
                state    <= S_REPLY_TX;
            end

            S_REPLY_TX: begin
                if (tx_valid && tx_ready) begin
                    tx_valid <= 1'b0;
                    case (tx_phase)
                        3'd1: tx_crc <= tx_crc_out;
                        3'd2: tx_crc <= tx_crc_out;
                        3'd3: tx_crc <= tx_crc_out;
                        default: ;
                    endcase

                    if (tx_phase == 3'd0) begin
                        tx_phase <= 3'd1;
                    end else if (tx_phase == 3'd1) begin
                        tx_phase <= 3'd2;
                    end else if (tx_phase == 3'd2) begin
                        if (rep_len == 8'h00)
                            tx_phase <= 3'd4;
                        else begin
                            tx_phase <= 3'd3;
                            tx_idx   <= 8'h00;
                        end
                    end else if (tx_phase == 3'd3) begin
                        if (tx_idx + 8'd1 == rep_len)
                            tx_phase <= 3'd4;
                        else
                            tx_idx <= tx_idx + 8'd1;
                    end else if (tx_phase == 3'd4) begin
                        state <= S_WAIT_SYNC;
                    end
                end else if (!tx_valid) begin
                    case (tx_phase)
                        3'd0: begin
                            tx_data  <= 8'h5A;
                            tx_valid <= 1'b1;
                        end
                        3'd1: begin
                            tx_data  <= rep_status;
                            tx_valid <= 1'b1;
                        end
                        3'd2: begin
                            tx_data  <= rep_len;
                            tx_valid <= 1'b1;
                        end
                        3'd3: begin
                            tx_data  <= reply_buf[tx_idx];
                            tx_valid <= 1'b1;
                        end
                        3'd4: begin
                            tx_data  <= tx_crc;
                            tx_valid <= 1'b1;
                        end
                        default: state <= S_WAIT_SYNC;
                    endcase
                end
            end

            default: state <= S_WAIT_SYNC;
            endcase
        end
    end

endmodule