`timescale 1ns/1ps
// tb_debounce.v
//
// Checks debounce with N = 16 so it runs fast.
// Run:
//   iverilog -o sim/tb_debounce.out rtl/debounce.v sim/tb_debounce.v
//   vvp sim/tb_debounce.out

module tb_debounce;

    reg clk = 0;
    always #5 clk = ~clk;

    reg  rst = 1;
    reg  in  = 0;
    wire level, pulse;

    debounce #(.N(16)) dut (
        .clk(clk), .rst(rst), .in(in), .level(level), .pulse(pulse)
    );

    // count every pulse we get
    integer pulses = 0;
    always @(posedge clk) if (pulse) pulses = pulses + 1;

    integer errors = 0;
    task check;
        input cond;
        input [8*64-1:0] msg;
        begin
            if (cond) $display("  PASS  %0s", msg);
            else begin
                $display("  FAIL  %0s", msg);
                errors = errors + 1;
            end
        end
    endtask

    // contacts chattering: flips quicker than N clocks, ends on 'final_val'
    task bounce;
        input final_val;
        integer k;
        begin
            for (k = 0; k < 5; k = k + 1) begin
                in = final_val;  repeat (3 + k) @(posedge clk);
                in = ~final_val; repeat (2) @(posedge clk);
            end
            in = final_val;
        end
    endtask

    initial begin
        $dumpfile("tb_debounce.vcd");
        $dumpvars(0, tb_debounce);

        repeat (5) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        $display("Test 1: bouncy press");
        bounce(1'b1);
        repeat (10) @(posedge clk);
        check(level == 1'b0, "not accepted before 16 stable clocks");
        repeat (20) @(posedge clk);
        check(level == 1'b1, "accepted once stable");
        check(pulses == 1,   "exactly one pulse for the whole press");

        $display("Test 2: short glitch while held");
        in = 0; repeat (8) @(posedge clk);
        in = 1; repeat (40) @(posedge clk);
        check(level == 1'b1, "8-clock glitch ignored");
        check(pulses == 1,   "no extra pulse");

        $display("Test 3: bouncy release");
        bounce(1'b0);
        repeat (40) @(posedge clk);
        check(level == 1'b0, "released");
        check(pulses == 1,   "no pulse on release");

        $display("Test 4: second clean press");
        in = 1; repeat (40) @(posedge clk);
        check(level == 1'b1 && pulses == 2, "second press gives second pulse");

        $display("");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d CHECK(S) FAILED", errors);
        $finish;
    end

endmodule