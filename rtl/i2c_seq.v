`timescale 1ns/1ps
// i2c_seq.v
//
// Transfer sequencer for Board M. Sits between the PC side (UART packets,
// Abhirup's parser) and i2c_master.
//
// How it's used:
//   1. PC sends data bytes. Each one arrives as store_valid/store_byte and
//      is kept in tx_buf. 'clear' empties the buffer.
//   2. PC sends a transfer request: req_addr (7-bit slave address) and
//      req_rw (0 = write, 1 = read). It waits here as "pending".
//   3. The transfer starts only while run_en is 1 (SW15, protocol on/off).
//      Once a transfer has started it always finishes, so the bus is never
//      left half way through a byte.
//
//   write: START, addr+W, REG_ADDR, tx_buf[0 .. count-1], STOP
//   read:  START, addr+W, REG_ADDR, START (repeated), addr+R,
//          read 'count' bytes (ACK all but the last, NACK the last), STOP
//
// Verify: every byte read back is compared with the byte stored at the same
// position. After a read, verify_ok = every byte matched. The read bytes
// also go out on rd_valid/rd_byte so the PC can check them as well.
//
// A NACK from the slave aborts the transfer (we still send STOP) and sets
// nack_err. A read with nothing stored sets empty_err without touching the bus.
// New store / clear / requests are ignored while a transfer is running.

module i2c_seq #(
    parameter DEPTH = 32,               // bytes we can store (max 240, the slave's data area)
    parameter [7:0] REG_ADDR = 8'h00    // slave register every transfer starts at
)(
    input  wire       clk,
    input  wire       rst,

    // ---- from the PC side ----
    input  wire       store_valid,      // one data byte to keep
    input  wire [7:0] store_byte,
    input  wire       clear,            // forget all stored bytes
    input  wire       req_valid,        // transfer request
    input  wire [6:0] req_addr,         // slave address, e.g. 7'h50
    input  wire       req_rw,           // 0 = write, 1 = read

    input  wire       run_en,           // protocol on/off (SW15 via mode_ctrl)

    // ---- to / from i2c_master ----
    output reg        m_cmd_valid,
    input  wire       m_cmd_ready,
    output reg  [2:0] m_cmd,
    output reg  [7:0] m_cmd_data,
    input  wire       m_rsp_valid,
    input  wire [7:0] m_rsp_data,
    input  wire       m_rsp_nack,

    // ---- back to the PC side ----
    output reg        rd_valid,         // one clock per byte read back
    output reg  [7:0] rd_byte,
    output reg        done,             // one clock when a transfer is finished
    output wire [7:0] status,           // {5'b0, empty_err, verify_bad, nack_err}

    // ---- for LEDs / display ----
    output reg  [7:0] count,            // bytes stored
    output reg        pending,          // request waiting for the ON switch
    output wire       busy,             // transfer running
    output reg  [7:0] last_stored,
    output reg  [7:0] last_read,
    output reg        verify_ok,        // last read matched (held until the next transfer)
    output reg        verify_bad,       // last read had at least one wrong byte
    output reg        nack_err,         // last transfer got a NACK
    output reg        empty_err,        // last request was a read with nothing stored
    output reg  [7:0] mism_cnt          // how many bytes differed in the last read
);

    // master command codes (same as i2c_master / interfaces.md)
    localparam CMD_START     = 3'd0;
    localparam CMD_WRITE     = 3'd1;
    localparam CMD_READ_ACK  = 3'd2;
    localparam CMD_READ_NACK = 3'd3;
    localparam CMD_STOP      = 3'd4;

    // sequencer states, one per master command in the transfer
    localparam Q_IDLE   = 4'd0;
    localparam Q_START  = 4'd1;   // START
    localparam Q_ADDR_W = 4'd2;   // address + write
    localparam Q_REG    = 4'd3;   // register pointer
    localparam Q_WDATA  = 4'd4;   // data bytes (write)
    localparam Q_RSTART = 4'd5;   // repeated START (read)
    localparam Q_ADDR_R = 4'd6;   // address + read
    localparam Q_RDATA  = 4'd7;   // data bytes (read)
    localparam Q_STOP   = 4'd8;   // STOP

    reg [7:0] tx_buf [0:DEPTH-1];
    reg [3:0] sq;
    reg [6:0] addr;
    reg       rw;
    reg [7:0] idx;        // which data byte we're on
    reg       issued;     // command sent, waiting for the master's answer

    assign busy   = (sq != Q_IDLE);
    assign status = {5'b0, empty_err, verify_bad, nack_err};

    wire last_byte = (idx == count - 8'd1);

    // ---------- the stored bytes ----------
    // own block, no reset, so synthesis can make it a small RAM
    wire store_ok = (sq == Q_IDLE) && store_valid && !clear && (count < DEPTH);

    always @(posedge clk)
        if (store_ok) tx_buf[count] <= store_byte;

    // ---------- which master command each state sends ----------
    reg [2:0] next_cmd;
    reg [7:0] next_data;

    always @(*) begin
        next_data = 8'h00;
        case (sq)
            Q_START,
            Q_RSTART: next_cmd = CMD_START;
            Q_ADDR_W: begin next_cmd = CMD_WRITE; next_data = {addr, 1'b0}; end
            Q_REG:    begin next_cmd = CMD_WRITE; next_data = REG_ADDR;     end
            Q_WDATA:  begin next_cmd = CMD_WRITE; next_data = tx_buf[idx];  end
            Q_ADDR_R: begin next_cmd = CMD_WRITE; next_data = {addr, 1'b1}; end
            Q_RDATA:  next_cmd = last_byte ? CMD_READ_NACK : CMD_READ_ACK;
            default:  next_cmd = CMD_STOP;
        endcase
    end

    // ---------- main state machine ----------
    always @(posedge clk) begin
        rd_valid <= 1'b0;     // pulses, default off
        done     <= 1'b0;

        if (rst) begin
            sq          <= Q_IDLE;
            issued      <= 1'b0;
            m_cmd_valid <= 1'b0;
            m_cmd       <= CMD_STOP;
            m_cmd_data  <= 8'h00;
            count       <= 8'd0;
            pending     <= 1'b0;
            addr        <= 7'd0;
            rw          <= 1'b0;
            idx         <= 8'd0;
            rd_byte     <= 8'h00;
            last_stored <= 8'h00;
            last_read   <= 8'h00;
            verify_ok   <= 1'b0;
            verify_bad  <= 1'b0;
            nack_err    <= 1'b0;
            empty_err   <= 1'b0;
            mism_cnt    <= 8'd0;
        end else begin

            // the master took our command -> stop offering it
            if (m_cmd_valid && m_cmd_ready)
                m_cmd_valid <= 1'b0;

            // send the command for the current state, once
            if (sq != Q_IDLE && !issued) begin
                m_cmd_valid <= 1'b1;
                m_cmd       <= next_cmd;
                m_cmd_data  <= next_data;
                issued      <= 1'b1;
            end

            case (sq)

            // ---- waiting: store bytes, take a request, start when ON ----
            Q_IDLE: begin
                if (clear)
                    count <= 8'd0;
                else if (store_ok) begin
                    count       <= count + 8'd1;
                    last_stored <= store_byte;
                end

                if (req_valid && !pending) begin
                    pending <= 1'b1;
                    addr    <= req_addr;
                    rw      <= req_rw;
                end

                if (pending && run_en) begin
                    // fresh results for this transfer
                    nack_err   <= 1'b0;
                    verify_ok  <= 1'b0;
                    verify_bad <= 1'b0;
                    empty_err  <= 1'b0;
                    mism_cnt   <= 8'd0;

                    if (rw && count == 0) begin
                        // a read with nothing stored has nothing to verify against
                        empty_err <= 1'b1;
                        pending   <= 1'b0;
                        done      <= 1'b1;
                    end else
                        sq <= Q_START;
                end
            end

            // ---- every other state: wait for the master's answer ----
            default: if (issued && m_rsp_valid) begin
                issued <= 1'b0;

                case (sq)
                    Q_START:  sq <= Q_ADDR_W;

                    Q_ADDR_W: if (m_rsp_nack) begin nack_err <= 1'b1; sq <= Q_STOP; end
                              else sq <= Q_REG;

                    Q_REG: begin
                        idx <= 8'd0;
                        if (m_rsp_nack)    begin nack_err <= 1'b1; sq <= Q_STOP; end
                        else if (rw)       sq <= Q_RSTART;
                        else if (count == 0) sq <= Q_STOP;    // nothing to write
                        else               sq <= Q_WDATA;
                    end

                    Q_WDATA:  if (m_rsp_nack)   begin nack_err <= 1'b1; sq <= Q_STOP; end
                              else if (last_byte) sq <= Q_STOP;
                              else                idx <= idx + 8'd1;

                    Q_RSTART: sq <= Q_ADDR_R;

                    Q_ADDR_R: if (m_rsp_nack) begin nack_err <= 1'b1; sq <= Q_STOP; end
                              else sq <= Q_RDATA;

                    Q_RDATA: begin
                        rd_valid  <= 1'b1;               // hand the byte to the PC side
                        rd_byte   <= m_rsp_data;
                        last_read <= m_rsp_data;
                        if (m_rsp_data != tx_buf[idx])   // compare with what we wrote
                            mism_cnt <= mism_cnt + 8'd1;
                        if (last_byte) sq <= Q_STOP;
                        else           idx <= idx + 8'd1;
                    end

                    Q_STOP: begin
                        // mism_cnt and nack_err are final by now
                        verify_ok  <= rw && !nack_err && (mism_cnt == 0);
                        verify_bad <= rw && !nack_err && (mism_cnt != 0);
                        pending    <= 1'b0;
                        done       <= 1'b1;
                        sq         <= Q_IDLE;
                    end

                    default: sq <= Q_IDLE;
                endcase
            end
            endcase
        end
    end

endmodule
