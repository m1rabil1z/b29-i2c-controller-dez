`timescale 1ns/1ps
// i2c_master.v
//
// Byte-level I2C master for Board M.
//
// The bridge gives it one command at a time (valid/ready handshake):
//   0 START      - START, or repeated START if we already have the bus
//   1 WRITE      - send cmd_data, then read the slave's ACK
//   2 READ_ACK   - read a byte and ACK it (more bytes coming)
//   3 READ_NACK  - read a byte and NACK it (last byte)
//   4 STOP
// When a command is done rsp_valid is high for one clock.
// WRITE: rsp_nack = 1 means the slave didn't ACK.
// READ:  the byte is in rsp_data.
//
// Every SCL period is split into 4 quarters:
//   q0  SCL low   just wait (hold time for the slaves after SCL falls)
//   q1  SCL low   SDA changes at the start of this quarter
//   q2  SCL high  let go of SCL, wait till it really reads high, sample SDA at the end
//   q3  SCL high  pull SCL low at the end
// SDA changes in the middle of the low time, not right at the falling edge.
// The slaves filter their inputs, so an SDA change right at the edge could
// show up while they still see SCL high = fake START/STOP.
//
// Clock stretching: in q2 the counter doesn't start until SCL actually reads
// high. If a slave holds SCL low we just wait. (Same trick gives clock sync
// in phase 2.)
//
// t_low / t_high are in clock cycles (100 MHz), from mode_ctrl.
// In step mode one step pulse = one quarter, the counter is ignored.
//
// Phase 1: bus_busy = "we sent START and no STOP yet", arb_lost tied to 0.

module i2c_master (
    input  wire        clk,
    input  wire        rst,        // synchronous, active high

    // commands from the bridge
    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire [2:0]  cmd,
    input  wire [7:0]  cmd_data,

    // result
    output reg         rsp_valid,
    output reg  [7:0]  rsp_data,
    output reg         rsp_nack,

    // speed, from mode_ctrl
    input  wire [24:0] t_low,
    input  wire [24:0] t_high,
    input  wire        step_mode,
    input  wire        step,

    // bus: 1 = pull low, 0 = let go. top_m turns these into open-drain pins
    output reg         scl_low,
    output reg         sda_low,
    input  wire        scl_in,
    input  wire        sda_in,

    // status / debug
    output wire        bus_busy,
    output wire        arb_lost,
    output wire [3:0]  dbg_state,
    output wire [7:0]  dbg_shift
);

    // command codes, same as interfaces.md
    localparam CMD_START     = 3'd0;
    localparam CMD_WRITE     = 3'd1;
    localparam CMD_READ_ACK  = 3'd2;
    localparam CMD_READ_NACK = 3'd3;
    localparam CMD_STOP      = 3'd4;

    localparam S_IDLE  = 4'd0;   // waiting for a command (SCL can be held low here, that's allowed)
    localparam S_START = 4'd1;
    localparam S_WRITE = 4'd2;
    localparam S_READ  = 4'd3;
    localparam S_STOP  = 4'd4;

    reg [3:0]  state;
    reg [1:0]  q;          // quarter of the current bit
    reg [3:0]  bit_cnt;    // 0-7 data bits, 8 = ACK bit
    reg [7:0]  shreg;
    reg [2:0]  cur_cmd;
    reg        owned;      // START sent, no STOP yet
    reg [24:0] cnt;

    // bus lines come from outside, sync them first
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

    // length of the current quarter.
    // normal bits: low and high time each split in half.
    // START/STOP need longer setup/hold (4.0-4.7 us at 100 kHz), so those get
    // the full t_high. Last quarter of STOP = bus free time before next START.
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

    // q2 starts by letting go of SCL. Until it reads high (sync delay,
    // rise time, or a slave stretching) we don't count.
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
                    // nothing to do on the bus without a START first.
                    // STOP here is harmless, just answer. WRITE/READ here
                    // means the bridge messed up, so flag it with nack.
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
                    state <= S_READ;     // READ_ACK or READ_NACK
            end

            // START / repeated START
            //   q0 end: let go of SDA (SCL still low if we had the bus)
            //   q1 end: let go of SCL
            //   q2 end: SCL high for t_high -> pull SDA low = START
            //   q3 end: held t_high -> pull SCL low, done
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

            // WRITE: 8 bits MSB first, bit 8 = slave's ACK
            S_WRITE: if (q_end) begin
                q <= q + 2'd1;
                case (q)
                    2'd0: sda_low <= (bit_cnt == 4'd8) ? 1'b0 : ~shreg[7];  // bit 8: let go so slave can ACK
                    2'd1: scl_low <= 1'b0;
                    2'd2: if (bit_cnt == 4'd8) rsp_nack <= sda;             // ACK = slave pulled SDA low
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

            // READ: let go of SDA for 8 bits and sample them,
            // bit 8 we drive our ACK (pull low) or NACK (let go)
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

            // STOP
            //   q0 end: pull SDA low (SCL is low)
            //   q1 end: let go of SCL
            //   q2 end: SCL high for t_high -> let go of SDA = STOP
            //   q3 end: wait t_low (bus free time), done
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
    assign arb_lost  = 1'b0;     // phase 2
    assign dbg_state = state;
    assign dbg_shift = shreg;

endmodule