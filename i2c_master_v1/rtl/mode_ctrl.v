`timescale 1ns/1ps
// mode_ctrl.v
//
// Board M control panel. Debounces all switches and buttons and turns them
// into settings for the master and the bridge.
//
//   SW15      0 = PC in control (pyserial), 1 = board in control (switches)
//   SW2-0     speed index when the board is in control
//   SW3       slave select, 0 = 0x50, 1 = 0x51
//   SW4       0 = write, 1 = read
//   SW5       step mode (board control only)
//   SW14      hidden debug mode: SW13 / SW12 drive SCL / SDA directly
//   BTNC      start a transfer (board control only)
//   BTNR      one step (in step mode)
//
// SCL speed is parameterized. Each of the 8 speeds is a frequency plus the %
// of the period SCL stays low. The cycle counts are worked out at compile time
// from CLK_HZ, so the FPGA only ever sees constants, no divider gets built.
// SYNC_DELAY: the master loses 2 clocks seeing SCL go high (its 2-flop sync),
// so we take those off t_high to get the exact frequency.
//
// This block never runs a transfer itself. start_pulse / slave_sel / rw go to
// the bridge, which sends the actual commands to the master, same as for
// pyserial packets.

module mode_ctrl #(
    parameter CLK_HZ     = 100_000_000,
    parameter DEB_N      = 1_000_000,   // debounce time in clocks (10 ms), tb makes it small
    parameter SYNC_DELAY = 2,

    // speed table:   frequency          % low
    parameter SPD0_HZ = 2,        SPD0_LOW = 50,   // watch bits on the LEDs
    parameter SPD1_HZ = 1_000,    SPD1_LOW = 50,   // scope
    parameter SPD2_HZ = 10_000,   SPD2_LOW = 50,
    parameter SPD3_HZ = 50_000,   SPD3_LOW = 50,
    parameter SPD4_HZ = 100_000,  SPD4_LOW = 50,   // standard mode, default
    parameter SPD5_HZ = 200_000,  SPD5_LOW = 50,
    parameter SPD6_HZ = 300_000,  SPD6_LOW = 50,
    parameter SPD7_HZ = 400_000,  SPD7_LOW = 60    // fast mode, 60% so low >= 1.3 us
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [15:0] sw,
    input  wire        btn_start,      // BTNC
    input  wire        btn_step,       // BTNR
    input  wire [2:0]  pc_speed_idx,   // from the bridge (SET_SPEED), bridge resets it to 4

    output wire        src_sel,        // 1 = board in control
    output wire [2:0]  speed_idx,      // speed actually in use, for the 7-seg
    output reg  [24:0] t_low,          // to the master
    output reg  [24:0] t_high,
    output wire        step_mode,
    output wire        step,
    output wire        start_pulse,    // to the bridge
    output wire        slave_sel,
    output wire        rw,
    output wire        dbg_en,         // to top_m: switches drive the pins
    output wire        dbg_scl_low,
    output wire        dbg_sda_low
);

    // ---------- debounce everything ----------
    wire [15:0] sw_lvl;

    genvar g;
    generate
        for (g = 0; g < 16; g = g + 1) begin : g_sw
            debounce #(.N(DEB_N)) u_db (
                .clk(clk), .rst(rst), .in(sw[g]),
                .level(sw_lvl[g]), .pulse()
            );
        end
    endgenerate

    wire start_p, step_p;

    debounce #(.N(DEB_N)) u_db_start (
        .clk(clk), .rst(rst), .in(btn_start), .level(), .pulse(start_p)
    );
    debounce #(.N(DEB_N)) u_db_step (
        .clk(clk), .rst(rst), .in(btn_step), .level(), .pulse(step_p)
    );

    // ---------- speed table ----------
    // returns {t_low, t_high} in clocks for one table entry
    function [49:0] lohi;
        input [63:0] hz;
        input [63:0] low_pct;
        reg   [63:0] p, lo, hi;
        begin
            p    = CLK_HZ / hz;               // clocks per SCL period
            lo   = p * low_pct / 100;
            hi   = p - lo - SYNC_DELAY;
            lohi = {lo[24:0], hi[24:0]};
        end
    endfunction

    localparam [49:0] SPD0 = lohi(SPD0_HZ, SPD0_LOW);
    localparam [49:0] SPD1 = lohi(SPD1_HZ, SPD1_LOW);
    localparam [49:0] SPD2 = lohi(SPD2_HZ, SPD2_LOW);
    localparam [49:0] SPD3 = lohi(SPD3_HZ, SPD3_LOW);
    localparam [49:0] SPD4 = lohi(SPD4_HZ, SPD4_LOW);
    localparam [49:0] SPD5 = lohi(SPD5_HZ, SPD5_LOW);
    localparam [49:0] SPD6 = lohi(SPD6_HZ, SPD6_LOW);
    localparam [49:0] SPD7 = lohi(SPD7_HZ, SPD7_LOW);

    // just a lookup, synthesizes to an 8:1 mux of constants
    function [49:0] spd;
        input [2:0] i;
        begin
            case (i)
                3'd0:    spd = SPD0;
                3'd1:    spd = SPD1;
                3'd2:    spd = SPD2;
                3'd3:    spd = SPD3;
                3'd4:    spd = SPD4;
                3'd5:    spd = SPD5;
                3'd6:    spd = SPD6;
                default: spd = SPD7;
            endcase
        end
    endfunction

    // ---------- who's in control ----------
    assign src_sel   = sw_lvl[15];
    assign speed_idx = src_sel ? sw_lvl[2:0] : pc_speed_idx;

    always @(*) {t_low, t_high} = spd(speed_idx);

    // ---------- the rest ----------
    assign slave_sel   = sw_lvl[3];
    assign rw          = sw_lvl[4];

    // step mode only under board control. If SW5 got left on, PC logs
    // would otherwise just hang waiting for button presses.
    assign step_mode   = sw_lvl[5] & src_sel;
    assign step        = step_p;

    // BTNC only counts when the board is in control and we're not in debug
    assign start_pulse = start_p & src_sel & ~dbg_en;

    // debug: switch up = line released (high), switch down = pulled low
    assign dbg_en      = sw_lvl[14];
    assign dbg_scl_low = ~sw_lvl[13];
    assign dbg_sda_low = ~sw_lvl[12];

    // ---------- I2C spec check, simulation only ----------
    // standard mode (<= 100 kHz): low >= 4.7 us, high >= 4.0 us
    // fast mode     (>  100 kHz): low >= 1.3 us, high >= 0.6 us
    // synthesis translate_off
    function spec_ok;
        input [49:0] lh;
        reg   [63:0] lo_ns, hi_ns;
        begin
            lo_ns = lh[49:25] * 64'd1_000_000_000 / CLK_HZ;
            hi_ns = (lh[24:0] + SYNC_DELAY) * 64'd1_000_000_000 / CLK_HZ;
            if (lo_ns + hi_ns < 10_000)
                spec_ok = (lo_ns >= 1300) && (hi_ns >= 600);
            else
                spec_ok = (lo_ns >= 4700) && (hi_ns >= 4000);
        end
    endfunction

    integer k;
    initial begin
        for (k = 0; k < 8; k = k + 1)
            if (!spec_ok(spd(k)))
                $display("ERROR mode_ctrl: speed %0d breaks the I2C timing spec", k);
    end
    // synthesis translate_on

endmodule