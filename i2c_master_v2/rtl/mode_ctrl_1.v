`timescale 1ns/1ps
// mode_ctrl.v
//
// Board M control panel. Debounces the switches and buttons and turns them
// into settings for the master and the sequencer.
//
//   SW15      protocol ON/OFF. A transfer request from the PC waits here
//             until this is on. (A transfer that already started finishes.)
//   SW2-0     SCL speed (index into the table below)
//   SW5       step mode, BTNR = one step
//   SW14      hidden debug mode: SW13 / SW12 drive SCL / SDA directly
//             (also forces the protocol off)
//
// Slave address and read/write now come from pyserial, not from switches.
//
// SCL speed is parameterized. Each of the 8 speeds is a frequency plus the %
// of the period SCL stays low. The cycle counts are worked out at compile time
// from CLK_HZ, so the FPGA only ever sees constants, no divider gets built.
// SYNC_DELAY: the master loses 2 clocks seeing SCL go high (its 2-flop sync),
// so we take those off t_high to get the exact frequency.

module mode_ctrl #(
    parameter CLK_HZ     = 100_000_000,
    parameter DEB_N      = 1_000_000,   // debounce time in clocks (10 ms), tb makes it small
    parameter SYNC_DELAY = 2,

    // speed table:   frequency          % low
    parameter SPD0_HZ = 2,        SPD0_LOW = 50,   // watch bits on the LEDs
    parameter SPD1_HZ = 1_000,    SPD1_LOW = 50,   // scope
    parameter SPD2_HZ = 10_000,   SPD2_LOW = 50,
    parameter SPD3_HZ = 50_000,   SPD3_LOW = 50,
    parameter SPD4_HZ = 100_000,  SPD4_LOW = 50,   // standard mode
    parameter SPD5_HZ = 200_000,  SPD5_LOW = 50,
    parameter SPD6_HZ = 300_000,  SPD6_LOW = 50,
    parameter SPD7_HZ = 400_000,  SPD7_LOW = 60    // fast mode, 60% so low >= 1.3 us
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [15:0] sw,
    input  wire        btn_step,       // BTNR

    output wire        run_en,         // to the sequencer: protocol on
    output wire [2:0]  speed_idx,      // for the 7-seg
    output reg  [24:0] t_low,          // to the master
    output reg  [24:0] t_high,
    output wire        step_mode,
    output wire        step,
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

    wire step_p;
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

    assign speed_idx = sw_lvl[2:0];
    always @(*) {t_low, t_high} = spd(speed_idx);

    // ---------- the rest ----------
    assign dbg_en      = sw_lvl[14];
    assign run_en      = sw_lvl[15] & ~dbg_en;   // never run the protocol while hand-driving the pins

    assign step_mode   = sw_lvl[5];
    assign step        = step_p;

    // debug: switch up = line released (high), switch down = pulled low
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