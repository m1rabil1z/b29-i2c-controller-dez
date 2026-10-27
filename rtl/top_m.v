`timescale 1ns/1ps
// top_m.v
//
// Board M top level (Basys 3). Connects:
//   USB-UART  -> uart_rx / uart_tx -> uart_bridge (Abhirup)
//   uart_bridge -> i2c_seq -> i2c_master -> open-drain SCL/SDA on Pmod JA
//   switches and buttons -> mode_ctrl
//   status -> LEDs and 7-segment display
//
// Controls:
//   SW15      protocol ON (a request from the PC waits until this is up)
//   SW2-0     SCL speed index (0 = 2 Hz ... 4 = 100 kHz ... 7 = 400 kHz)
//   SW5, BTNR step mode, one quarter-bit per press
//   SW14      debug: SW13 / SW12 drive SCL / SDA directly (protocol forced off)
//   BTNU      reset
//
// LEDs:
//   LD15 SCL   LD14 SDA   LD13 protocol ON   LD12 busy   LD11 pending
//   LD10 NACK  LD9 verify bad   LD8 verify OK
//   LD7-0 last byte stored (or last byte read back, after a read)
//
// Display: digits 3-2 = bytes stored (hex), digit 1 = speed index,
//          digit 0 = last result (0 ok, 2 NACK, 8 mismatch, 9 nothing stored)
//          DP3 = debug mode, DP0 = protocol ON
//
// Pull-ups: internal, set by PULLUP in basys3_m.xdc (Basys 3 resources only).

module top_m #(
    parameter DEB_N           = 1_000_000,   // 10 ms debounce; testbenches make it small
    parameter TICKS_PER_DIGIT = 100_000      // display refresh; testbenches make it small
)(
    input  wire        clk,        // 100 MHz, W5
    input  wire        btnU,       // reset
    input  wire        btnR,       // step
    input  wire [15:0] sw,
    output wire [15:0] led,
    output wire [6:0]  seg,
    output wire        dp,
    output wire [3:0]  an,
    input  wire        RsRx,       // UART from the PC (B18)
    output wire        RsTx,       // UART to the PC (A18)
    inout  wire        scl_pin,    // JA1
    inout  wire        sda_pin     // JA2
);

    // ---------- reset ----------
    wire rst;
    debounce #(.N(DEB_N)) u_db_rst (
        .clk(clk), .rst(1'b0), .in(btnU), .level(rst), .pulse()
    );

    // ---------- control panel ----------
    wire        run_en, step_mode, step, dbg_en, dbg_scl_low, dbg_sda_low;
    wire [2:0]  speed_idx;
    wire [24:0] t_low, t_high;

    mode_ctrl #(.DEB_N(DEB_N)) u_mode (
        .clk(clk), .rst(rst), .sw(sw), .btn_step(btnR),
        .run_en(run_en), .speed_idx(speed_idx), .t_low(t_low), .t_high(t_high),
        .step_mode(step_mode), .step(step),
        .dbg_en(dbg_en), .dbg_scl_low(dbg_scl_low), .dbg_sda_low(dbg_sda_low)
    );

    // ---------- laptop link ----------
    wire [7:0] rx_data, tx_data;
    wire       rx_valid, tx_valid, tx_ready;

    uart_rx u_rx (.clk(clk), .rst(rst), .rx(RsRx), .data(rx_data), .valid(rx_valid), .frame_err());
    uart_tx u_tx (.clk(clk), .rst(rst), .data(tx_data), .valid(tx_valid), .ready(tx_ready), .tx(RsTx));

    wire       store_valid, clear, req_valid, req_rw;
    wire [7:0] store_byte;
    wire [6:0] req_addr;
    wire       rd_valid, done, pending, busy;
    wire [7:0] rd_byte, status, count;

    uart_bridge u_br (
        .clk(clk), .rst(rst),
        .rx_data(rx_data), .rx_valid(rx_valid),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .store_valid(store_valid), .store_byte(store_byte), .clear(clear),
        .req_valid(req_valid), .req_addr(req_addr), .req_rw(req_rw),
        .count(count), .busy(busy), .pending(pending),
        .rd_valid(rd_valid), .rd_byte(rd_byte), .done(done), .status(status)
    );

    // ---------- sequencer + master ----------
    wire       m_cmd_valid, m_cmd_ready, m_rsp_valid, m_rsp_nack;
    wire [2:0] m_cmd;
    wire [7:0] m_cmd_data, m_rsp_data;
    wire [7:0] last_stored, last_read, mism_cnt;
    wire       verify_ok, verify_bad, nack_err, empty_err;
    wire       m_scl_low, m_sda_low;

    i2c_seq #(.DEPTH(32)) u_seq (
        .clk(clk), .rst(rst),
        .store_valid(store_valid), .store_byte(store_byte), .clear(clear),
        .req_valid(req_valid), .req_addr(req_addr), .req_rw(req_rw), .run_en(run_en),
        .m_cmd_valid(m_cmd_valid), .m_cmd_ready(m_cmd_ready), .m_cmd(m_cmd), .m_cmd_data(m_cmd_data),
        .m_rsp_valid(m_rsp_valid), .m_rsp_data(m_rsp_data), .m_rsp_nack(m_rsp_nack),
        .rd_valid(rd_valid), .rd_byte(rd_byte), .done(done), .status(status),
        .count(count), .pending(pending), .busy(busy),
        .last_stored(last_stored), .last_read(last_read),
        .verify_ok(verify_ok), .verify_bad(verify_bad),
        .nack_err(nack_err), .empty_err(empty_err), .mism_cnt(mism_cnt)
    );

    i2c_master u_master (
        .clk(clk), .rst(rst),
        .cmd_valid(m_cmd_valid), .cmd_ready(m_cmd_ready), .cmd(m_cmd), .cmd_data(m_cmd_data),
        .rsp_valid(m_rsp_valid), .rsp_data(m_rsp_data), .rsp_nack(m_rsp_nack),
        .t_low(t_low), .t_high(t_high), .step_mode(step_mode), .step(step),
        .scl_low(m_scl_low), .sda_low(m_sda_low), .scl_in(scl_pin), .sda_in(sda_pin),
        .bus_busy(), .arb_lost(), .dbg_state(), .dbg_shift()
    );

    // ---------- pins: open drain, debug mux ----------
    // pull low or let go, never drive high. The pull-up (XDC PULLUP) makes it high.
    wire scl_pull = dbg_en ? dbg_scl_low : m_scl_low;
    wire sda_pull = dbg_en ? dbg_sda_low : m_sda_low;

    assign scl_pin = scl_pull ? 1'b0 : 1'bz;
    assign sda_pin = sda_pull ? 1'b0 : 1'bz;

    // ---------- LEDs ----------
    reg show_read = 1'b0;    // after a read, LD7-0 show the byte read back
    always @(posedge clk) begin
        if (rst)              show_read <= 1'b0;
        else if (rd_valid)    show_read <= 1'b1;
        else if (store_valid) show_read <= 1'b0;
    end

    assign led = {scl_pin, sda_pin, run_en, busy, pending, nack_err, verify_bad, verify_ok,
                  show_read ? last_read : last_stored};

    // ---------- display ----------
    wire [3:0] result = nack_err   ? 4'h2 :
                        empty_err  ? 4'h9 :
                        verify_bad ? 4'h8 : 4'h0;

    seg7 #(.TICKS_PER_DIGIT(TICKS_PER_DIGIT)) u_seg7 (
        .clk(clk), .rst(rst),
        .val({count, 1'b0, speed_idx, result}),
        .dots({dbg_en, 1'b0, 1'b0, run_en}),
        .an(an), .seg(seg), .dp(dp)
    );

endmodule
