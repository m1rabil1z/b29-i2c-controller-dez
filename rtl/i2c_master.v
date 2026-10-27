`timescale 1ns/1ps
module i2c_master (
    input  wire        clk,
    input  wire        rst,
    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire [2:0]  cmd,
    input  wire [7:0]  cmd_data,
    output reg         rsp_valid,
    output reg  [7:0]  rsp_data,
    output reg         rsp_nack,
    input  wire [24:0] t_low,
    input  wire [24:0] t_high,
    input  wire        step_mode,
    input  wire        step,
    output reg         scl_low,
    output reg         sda_low,
    input  wire        scl_in,
    input  wire        sda_in,
    output wire        bus_busy,
    output wire        arb_lost,
    output wire [3:0]  dbg_state,
    output wire [7:0]  dbg_shift
);
    localparam CMD_START     = 3'd0;
    localparam CMD_WRITE     = 3'd1;
    localparam CMD_READ_ACK  = 3'd2;
    localparam CMD_READ_NACK = 3'd3;
    localparam CMD_STOP      = 3'd4;
    localparam S_IDLE  = 4'd0;
    localparam S_START = 4'd1;
    localparam S_WRITE = 4'd2;
    localparam S_READ  = 4'd3;
    localparam S_STOP  = 4'd4;
    reg [3:0]  state;
    reg [1:0]  q;
    reg [3:0]  bit_cnt;
    reg [7:0]  shreg;
    reg [2:0]  cur_cmd;
    reg        owned;
    reg [24:0] cnt;
    reg [1:0] scl_sync, sda_sync;
    always @(posedge clk) begin
        if (rst) begin
            scl_sync <= 2'b11;
            sda_sync <= 2'b11;
        end else begin
            scl_sync <= {scl_sync[0], scl_in};
            sda_sync <= {sda_sync[0], sda_in};
        end
    end
    wire scl = scl_sync[1];
    wire sda = sda_sync[1];
    reg [24:0] dur;
    always @(*) begin
        case (q)
            2'd0: dur = t_low >> 1;
            2'd1: dur = t_low - (t_low >> 1);
            2'd2: dur = (state == S_START || state == S_STOP) ? t_high : (t_high >> 1);
            2'd3: begin
                if (state == S_START)     dur = t_high;
                else if (state == S_STOP) dur = t_low;
                else                      dur = t_high - (t_high >> 1);
            end
        endcase
    end
    wire waiting = (q == 2'd2) && !scl;
    wire q_end = (state != S_IDLE) && !waiting &&
                 (step_mode ? step : (cnt + 25'd1 >= dur));
    always @(posedge clk) begin
        if (rst || state == S_IDLE || waiting || q_end)
            cnt <= 25'd0;
        else
            cnt <= cnt + 25'd1;
    end
    always @(posedge clk) begin
        rsp_valid <= 1'b0;
        if (rst) begin
            state    <= S_IDLE;
            q        <= 2'd0;
            bit_cnt  <= 4'd0;
            shreg    <= 8'd0;
            cur_cmd  <= 3'd0;
            owned    <= 1'b0;
            scl_low  <= 1'b0;
            sda_low  <= 1'b0;
            rsp_data <= 8'd0;
            rsp_nack <= 1'b0;
        end else begin
            case (state)
            S_IDLE: if (cmd_valid) begin
                cur_cmd  <= cmd;
                q        <= 2'd0;
                bit_cnt  <= 4'd0;
                rsp_nack <= 1'b0;
                if (cmd == CMD_START)
                    state <= S_START;
                else if (!owned || cmd > CMD_STOP) begin
                    rsp_valid <= 1'b1;
                    rsp_nack  <= (cmd != CMD_STOP);
                end
                else if (cmd == CMD_WRITE) begin
                    shreg <= cmd_data;
                    state <= S_WRITE;
                end
                else if (cmd == CMD_STOP)
                    state <= S_STOP;
                else
                    state <= S_READ;
            end
            S_START: if (q_end) begin
                q <= q + 2'd1;
                case (q)
                    2'd0: sda_low <= 1'b0;
                    2'd1: scl_low <= 1'b0;
                    2'd2: sda_low <= 1'b1;
                    2'd3: begin
                        scl_low   <= 1'b1;
                        owned     <= 1'b1;
                        rsp_valid <= 1'b1;
                        state     <= S_IDLE;
                    end
                endcase
            end
            S_WRITE: if (q_end) begin
                q <= q + 2'd1;
                case (q)
                    2'd0: sda_low <= (bit_cnt == 4'd8) ? 1'b0 : ~shreg[7];
                    2'd1: scl_low <= 1'b0;
                    2'd2: if (bit_cnt == 4'd8) rsp_nack <= sda;
                    2'd3: begin
                        scl_low <= 1'b1;
                        if (bit_cnt == 4'd8) begin
                            rsp_valid <= 1'b1;
                            state     <= S_IDLE;
                        end else begin
                            shreg   <= {shreg[6:0], 1'b0};
                            bit_cnt <= bit_cnt + 4'd1;
                        end
                    end
                endcase
            end
            S_READ: if (q_end) begin
                q <= q + 2'd1;
                case (q)
                    2'd0: sda_low <= (bit_cnt == 4'd8) && (cur_cmd == CMD_READ_ACK);
                    2'd1: scl_low <= 1'b0;
                    2'd2: if (bit_cnt != 4'd8) shreg <= {shreg[6:0], sda};
                    2'd3: begin
                        scl_low <= 1'b1;
                        if (bit_cnt == 4'd8) begin
                            rsp_data  <= shreg;
                            rsp_valid <= 1'b1;
                            state     <= S_IDLE;
                        end else
                            bit_cnt <= bit_cnt + 4'd1;
                    end
                endcase
            end
            S_STOP: if (q_end) begin
                q <= q + 2'd1;
                case (q)
                    2'd0: sda_low <= 1'b1;
                    2'd1: scl_low <= 1'b0;
                    2'd2: sda_low <= 1'b0;
                    2'd3: begin
                        owned     <= 1'b0;
                        rsp_valid <= 1'b1;
                        state     <= S_IDLE;
                    end
                endcase
            end
            default: state <= S_IDLE;
            endcase
        end
    end
    assign cmd_ready = (state == S_IDLE);
    assign bus_busy  = owned;
    assign arb_lost  = 1'b0;
    assign dbg_state = state;
    assign dbg_shift = shreg;
endmodule
