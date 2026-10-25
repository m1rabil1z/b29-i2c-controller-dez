`timescale 1ns/1ps

module tb_bus;

    reg clk = 0;
    always #5 clk = ~clk; // 100 MHz (10 ns period)

    reg rst = 1;

    // Master command interface
    reg        cmd_valid;
    wire       cmd_ready;
    reg  [2:0] cmd;
    reg  [7:0] cmd_data;

    wire       rsp_valid;
    wire [7:0] rsp_data;
    wire       rsp_nack;

    // Bus lines (wired-AND open-drain)
    wire m_scl_low, m_sda_low;
    wire s0_sda_low, s1_sda_low;

    wire scl = ~m_scl_low;
    wire sda = ~(m_sda_low | s0_sda_low | s1_sda_low);

    // Command encodings
    localparam CMD_START     = 3'd0;
    localparam CMD_WRITE     = 3'd1;
    localparam CMD_READ_ACK  = 3'd2;
    localparam CMD_READ_NACK = 3'd3;
    localparam CMD_STOP      = 3'd4;

    // Timing parameters for 100 kHz Standard Mode
    reg [24:0] t_low  = 25'd500;
    reg [24:0] t_high = 25'd500;

    // 1. Master instance
    i2c_master u_master (
        .clk       (clk),
        .rst       (rst),
        .cmd_valid (cmd_valid),
        .cmd_ready (cmd_ready),
        .cmd       (cmd),
        .cmd_data  (cmd_data),
        .rsp_valid (rsp_valid),
        .rsp_data  (rsp_data),
        .rsp_nack  (rsp_nack),
        .t_low     (t_low),
        .t_high    (t_high),
        .step_mode (1'b0),
        .step      (1'b0),
        .scl_low   (m_scl_low),
        .sda_low   (m_sda_low),
        .scl_in    (scl),
        .sda_in    (sda),
        .bus_busy  (),
        .arb_lost  (),
        .dbg_state (),
        .dbg_shift ()
    );

    // 2. Real Slave 0 (Address 0x50, WHO = 0xC1)
    i2c_slave #(
        .ADDR(7'h50),
        .WHO (8'hC1)
    ) slave0 (
        .clk       (clk),
        .rst       (rst),
        .scl_in    (scl),
        .sda_in    (sda),
        .sda_low   (s0_sda_low),
        .force_nack(1'b0),
        .invert    (1'b0),
        .sw_in     (8'h5A),
        .last_byte (),
        .addressed ()
    );

    // 3. Real Slave 1 (Address 0x51, WHO = 0xC2)
    i2c_slave #(
        .ADDR(7'h51),
        .WHO (8'hC2)
    ) slave1 (
        .clk       (clk),
        .rst       (rst),
        .scl_in    (scl),
        .sda_in    (sda),
        .sda_low   (s1_sda_low),
        .force_nack(1'b0),
        .invert    (1'b0),
        .sw_in     (8'hA5),
        .last_byte (),
        .addressed ()
    );

    task send_cmd;
        input [2:0] c;
        input [7:0] d;
        begin
            wait(cmd_ready);
            @(posedge clk);
            cmd       <= c;
            cmd_data  <= d;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;
            wait(rsp_valid);
            @(posedge clk);
        end
    endtask

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check;
        input         cond;
        input [511:0] msg;
        begin
            if (cond) begin
                $display("  [PASS] %0s", msg);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  [FAIL] %0s (time %0t)", msg, $time);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_bus.vcd");
        $dumpvars(0, tb_bus);

        cmd_valid = 0;
        cmd       = 0;
        cmd_data  = 0;

        #200;
        rst = 0;
        #200;

        $display("\n========================================");
        $display("  Starting Ring 2: Bus Integration Tests");
        $display("========================================\n");

        // Test 1: Single byte write to Slave 0 (0x50)
        send_cmd(CMD_START, 8'h00);
        send_cmd(CMD_WRITE, {7'h50, 1'b0});
        check(rsp_nack == 1'b0, "Test 1a: Master addressed Slave 0 (0x50+W) successfully");
        send_cmd(CMD_WRITE, 8'h10); // reg pointer 0x10
        send_cmd(CMD_WRITE, 8'hAA); // data 0xAA
        send_cmd(CMD_STOP,  8'h00);
        check(slave0.mem[8'h10] == 8'hAA, "Test 1b: Slave 0 stored 0xAA at register 0x10");

        // Test 2: Single byte write to Slave 1 (0x51)
        send_cmd(CMD_START, 8'h00);
        send_cmd(CMD_WRITE, {7'h51, 1'b0});
        check(rsp_nack == 1'b0, "Test 2a: Master addressed Slave 1 (0x51+W) successfully");
        send_cmd(CMD_WRITE, 8'h20); // reg pointer 0x20
        send_cmd(CMD_WRITE, 8'h55); // data 0x55
        send_cmd(CMD_STOP,  8'h00);
        check(slave1.mem[8'h20] == 8'h55, "Test 2b: Slave 1 stored 0x55 at register 0x20");

        // Test 3: Verify isolation
        check(slave0.mem[8'h20] == 8'h00, "Test 3: Slave 0 memory unaffected by Slave 1 write");

        // Test 4: Burst write and read back via Repeated START
        send_cmd(CMD_START, 8'h00);
        send_cmd(CMD_WRITE, {7'h50, 1'b0});
        send_cmd(CMD_WRITE, 8'h30);
        send_cmd(CMD_WRITE, 8'h11);
        send_cmd(CMD_WRITE, 8'h22);
        send_cmd(CMD_WRITE, 8'h33);
        // Repeated START to read
        send_cmd(CMD_START, 8'h00);
        send_cmd(CMD_WRITE, {7'h50, 1'b0});
        send_cmd(CMD_WRITE, 8'h30);
        send_cmd(CMD_START, 8'h00);
        send_cmd(CMD_WRITE, {7'h50, 1'b1});
        send_cmd(CMD_READ_ACK,  8'h00); check(rsp_data == 8'h11, "Test 4a: Byte 0 read 0x11");
        send_cmd(CMD_READ_ACK,  8'h00); check(rsp_data == 8'h22, "Test 4b: Byte 1 read 0x22");
        send_cmd(CMD_READ_NACK, 8'h00); check(rsp_data == 8'h33, "Test 4c: Byte 2 read 0x33 with Master NACK");
        send_cmd(CMD_STOP, 8'h00);

        // Test 5: Verify WHO_AM_I for both slaves
        send_cmd(CMD_START, 8'h00);
        send_cmd(CMD_WRITE, {7'h50, 1'b0});
        send_cmd(CMD_WRITE, 8'hF0);
        send_cmd(CMD_START, 8'h00);
        send_cmd(CMD_WRITE, {7'h50, 1'b1});
        send_cmd(CMD_READ_NACK, 8'h00);
        check(rsp_data == 8'hC1, "Test 5a: Slave 0 WHO_AM_I returned 0xC1");
        send_cmd(CMD_STOP, 8'h00);

        send_cmd(CMD_START, 8'h00);
        send_cmd(CMD_WRITE, {7'h51, 1'b0});
        send_cmd(CMD_WRITE, 8'hF0);
        send_cmd(CMD_START, 8'h00);
        send_cmd(CMD_WRITE, {7'h51, 1'b1});
        send_cmd(CMD_READ_NACK, 8'h00);
        check(rsp_data == 8'hC2, "Test 5b: Slave 1 WHO_AM_I returned 0xC2");
        send_cmd(CMD_STOP, 8'h00);

        // Test 7: Fast Mode (400 kHz)
        t_low  = 25'd150;
        t_high = 25'd100;
        send_cmd(CMD_START, 8'h00);
        send_cmd(CMD_WRITE, {7'h50, 1'b0});
        send_cmd(CMD_WRITE, 8'h10);
        send_cmd(CMD_START, 8'h00);
        send_cmd(CMD_WRITE, {7'h50, 1'b1});
        send_cmd(CMD_READ_NACK, 8'h00);
        check(rsp_data == 8'hAA, "Test 7: 400 kHz Fast Mode transfer passed");
        send_cmd(CMD_STOP, 8'h00);

        // Test 8: NACK response on unmapped address 0x44
        send_cmd(CMD_START, 8'h00);
        send_cmd(CMD_WRITE, {7'h44, 1'b0});
        check(rsp_nack == 1'b1, "Test 8: Master detected NACK on unmapped address 0x44");
        send_cmd(CMD_STOP, 8'h00);

        $display("\n========================================");
        $display("  Ring 2 Summary: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $display("========================================\n");
        $finish;
    end

endmodule