`timescale 1ns/1ps

module tb_uart_bridge;

    reg clk;
    reg rst;

    reg [7:0]  tb_tx_data;
    reg        tb_tx_valid;
    wire       tb_tx_ready;
    wire       tb_tx_wire;

    wire [7:0] tb_rx_data;
    wire       tb_rx_valid;
    wire       tb_rx_frame_err;

    wire [7:0] br_tx_data;
    wire       br_tx_valid;
    wire       br_tx_ready;
    wire       br_tx_wire;

    wire [7:0] br_rx_data;
    wire       br_rx_valid;
    wire       br_rx_frame_err;

    wire       store_valid;
    wire [7:0] store_byte;
    wire       clear;
    wire       req_valid;
    wire [6:0] req_addr;
    wire       req_rw;
    wire [7:0] seq_count;
    wire       seq_busy;
    wire       seq_pending;
    wire       seq_rd_valid;
    wire [7:0] seq_rd_byte;
    wire       seq_done;
    wire [7:0] seq_status;

    reg  run_en;
    wire m_cmd_valid;
    wire m_cmd_ready;
    wire [2:0] m_cmd;
    wire [7:0] m_cmd_data;
    wire m_rsp_valid;
    wire [7:0] m_rsp_data;
    wire m_rsp_nack;

    wire scl_low;
    wire sda_low;
    wire scl_bus;
    wire sda_bus;

    pullup(scl_bus);
    pullup(sda_bus);

    assign scl_bus = scl_low ? 1'b0 : 1'bz;
    assign sda_bus = sda_low ? 1'b0 : 1'bz;

    wire s1_sda_low;
    wire s2_sda_low;
    assign sda_bus = (s1_sda_low | s2_sda_low) ? 1'b0 : 1'bz;

    uart_tx #(.CLK_HZ(100_000_000), .BAUD(115_200)) u_tb_tx (
        .clk(clk), .rst(rst),
        .data(tb_tx_data), .valid(tb_tx_valid),
        .ready(tb_tx_ready), .tx(tb_tx_wire)
    );

    uart_rx #(.CLK_HZ(100_000_000), .BAUD(115_200)) u_br_rx (
        .clk(clk), .rst(rst),
        .rx(tb_tx_wire),
        .data(br_rx_data), .valid(br_rx_valid), .frame_err(br_rx_frame_err)
    );

    uart_bridge u_bridge (
        .clk(clk), .rst(rst),
        .rx_data(br_rx_data), .rx_valid(br_rx_valid),
        .tx_data(br_tx_data), .tx_valid(br_tx_valid), .tx_ready(br_tx_ready),
        .store_valid(store_valid), .store_byte(store_byte), .clear(clear),
        .req_valid(req_valid), .req_addr(req_addr), .req_rw(req_rw),
        .count(seq_count), .busy(seq_busy), .pending(seq_pending),
        .rd_valid(seq_rd_valid), .rd_byte(seq_rd_byte),
        .done(seq_done), .status(seq_status)
    );

    uart_tx #(.CLK_HZ(100_000_000), .BAUD(115_200)) u_br_tx (
        .clk(clk), .rst(rst),
        .data(br_tx_data), .valid(br_tx_valid),
        .ready(br_tx_ready), .tx(br_tx_wire)
    );

    uart_rx #(.CLK_HZ(100_000_000), .BAUD(115_200)) u_tb_rx (
        .clk(clk), .rst(rst),
        .rx(br_tx_wire),
        .data(tb_rx_data), .valid(tb_rx_valid), .frame_err(tb_rx_frame_err)
    );

    i2c_seq #(.DEPTH(32), .REG_ADDR(8'h00)) u_seq (
        .clk(clk), .rst(rst),
        .store_valid(store_valid), .store_byte(store_byte), .clear(clear),
        .req_valid(req_valid), .req_addr(req_addr), .req_rw(req_rw),
        .run_en(run_en),
        .m_cmd_valid(m_cmd_valid), .m_cmd_ready(m_cmd_ready),
        .m_cmd(m_cmd), .m_cmd_data(m_cmd_data),
        .m_rsp_valid(m_rsp_valid), .m_rsp_data(m_rsp_data), .m_rsp_nack(m_rsp_nack),
        .rd_valid(seq_rd_valid), .rd_byte(seq_rd_byte),
        .done(seq_done), .status(seq_status),
        .count(seq_count), .pending(seq_pending), .busy(seq_busy),
        .last_stored(), .last_read(), .verify_ok(), .verify_bad(),
        .nack_err(), .empty_err(), .mism_cnt()
    );

    i2c_master u_master (
        .clk(clk), .rst(rst),
        .cmd_valid(m_cmd_valid), .cmd_ready(m_cmd_ready),
        .cmd(m_cmd), .cmd_data(m_cmd_data),
        .rsp_valid(m_rsp_valid), .rsp_data(m_rsp_data), .rsp_nack(m_rsp_nack),
        .t_low(25'd500), .t_high(25'd498),
        .step_mode(1'b0), .step(1'b0),
        .scl_low(scl_low), .sda_low(sda_low),
        .scl_in(scl_bus), .sda_in(sda_bus),
        .bus_busy(), .arb_lost(), .dbg_state(), .dbg_shift()
    );

    i2c_slave #(.ADDR(7'h50), .WHO(8'hC1)) u_slave1 (
        .clk(clk), .rst(rst),
        .scl_in(scl_bus), .sda_in(sda_bus), .sda_low(s1_sda_low),
        .force_nack(1'b0), .invert(1'b0), .sw_in(8'h00),
        .last_byte(), .addressed()
    );

    i2c_slave #(.ADDR(7'h51), .WHO(8'hC2)) u_slave2 (
        .clk(clk), .rst(rst),
        .scl_in(scl_bus), .sda_in(sda_bus), .sda_low(s2_sda_low),
        .force_nack(1'b0), .invert(1'b0), .sw_in(8'h00),
        .last_byte(), .addressed()
    );

    always #5 clk = ~clk;

    function [7:0] crc8_byte_fn;
        input [7:0] crc_in;
        input [7:0] d;
        reg [7:0] c;
        integer i;
        begin
            c = crc_in ^ d;
            for (i = 0; i < 8; i = i + 1) begin
                if (c[7])
                    c = ((c << 1) ^ 8'h07);
                else
                    c = (c << 1);
            end
            crc8_byte_fn = c & 8'hFF;
        end
    endfunction

    reg [7:0] req_bytes [0:63];
    reg [7:0] exp_bytes [0:63];
    reg [7:0] rx_reply [0:63];
    integer   rx_count;
    integer   test_fail_cnt;

    function [7:0] calc_req_crc;
        input integer body_len;
        reg [7:0] c;
        integer i;
        begin
            c = 8'h00;
            for (i = 0; i < body_len; i = i + 1)
                c = crc8_byte_fn(c, req_bytes[1 + i]);
            calc_req_crc = c;
        end
    endfunction

    function [7:0] calc_exp_crc;
        input integer body_len;
        reg [7:0] c;
        integer i;
        begin
            c = 8'h00;
            for (i = 0; i < body_len; i = i + 1)
                c = crc8_byte_fn(c, exp_bytes[1 + i]);
            calc_exp_crc = c;
        end
    endfunction

    always @(posedge clk) begin
        if (rst)
            rx_count <= 0;
        else if (tb_rx_valid) begin
            rx_reply[rx_count] <= tb_rx_data;
            rx_count <= rx_count + 1;
        end
    end

    task send_byte;
        input [7:0] b;
        begin
            while (!tb_tx_ready) @(posedge clk);
            tb_tx_data  <= b;
            tb_tx_valid <= 1'b1;
            @(posedge clk);
            tb_tx_valid <= 1'b0;
            repeat (8700) @(posedge clk);
            while (!tb_tx_ready) @(posedge clk);
        end
    endtask

    task send_pkt;
        input integer len;
        integer i;
        begin
            @(posedge clk);
            rx_count = 0;
            for (i = 0; i < len; i = i + 1)
                send_byte(req_bytes[i]);
        end
    endtask

    task check_reply;
        input integer exp_len;
        input [8*32-1:0] test_name;
        integer i;
        integer timeout;
        reg match;
        begin
            timeout = 0;
            while (rx_count < exp_len && timeout < 500_000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            if (timeout >= 500_000) begin
                $display("FAIL: %s (TIMEOUT waiting for reply, rx_count=%0d)", test_name, rx_count);
                test_fail_cnt = test_fail_cnt + 1;
            end else begin
                match = 1;
                if (rx_count != exp_len)
                    match = 0;
                else begin
                    for (i = 0; i < exp_len; i = i + 1) begin
                        if (rx_reply[i] !== exp_bytes[i])
                            match = 0;
                    end
                end
                if (match)
                    $display("PASS: %s", test_name);
                else begin
                    $display("FAIL: %s", test_name);
                    $write("  Expected: ");
                    for (i = 0; i < exp_len; i = i + 1) $write("%02X ", exp_bytes[i]);
                    $write("\n  Got:      ");
                    for (i = 0; i < rx_count; i = i + 1) $write("%02X ", rx_reply[i]);
                    $write("\n");
                    test_fail_cnt = test_fail_cnt + 1;
                end
            end
            $fflush();
        end
    endtask

    integer k;

    initial begin
        $display("Starting UART Bridge Simulation...");
        $fflush();
        clk = 0;
        rst = 1;
        run_en = 1;
        tb_tx_data = 0;
        tb_tx_valid = 0;
        test_fail_cnt = 0;
        #200;
        rst = 0;
        #200;

        req_bytes[0]=8'hA5; req_bytes[1]=8'h04; req_bytes[2]=8'h00; req_bytes[3]=8'h00;
        req_bytes[4]=8'h02; req_bytes[5]=8'hAB; req_bytes[6]=8'hCD; req_bytes[7]=calc_req_crc(6);
        exp_bytes[0]=8'h5A; exp_bytes[1]=8'h00; exp_bytes[2]=8'h02; exp_bytes[3]=8'hAB;
        exp_bytes[4]=8'hCD; exp_bytes[5]=calc_exp_crc(4);
        send_pkt(8);
        check_reply(6, "1. ECHO AB CD");

        req_bytes[0]=8'hA5; req_bytes[1]=8'h05; req_bytes[2]=8'h00; req_bytes[3]=8'h00;
        req_bytes[4]=8'h03; req_bytes[5]=8'h11; req_bytes[6]=8'h22; req_bytes[7]=8'h33; req_bytes[8]=calc_req_crc(7);
        exp_bytes[0]=8'h5A; exp_bytes[1]=8'h00; exp_bytes[2]=8'h00; exp_bytes[3]=calc_exp_crc(2);
        send_pkt(9);
        check_reply(4, "2a. STORE 11 22 33");

        req_bytes[0]=8'hA5; req_bytes[1]=8'h06; req_bytes[2]=8'h50; req_bytes[3]=8'h00;
        req_bytes[4]=8'h00; req_bytes[5]=calc_req_crc(4);
        exp_bytes[0]=8'h5A; exp_bytes[1]=8'h00; exp_bytes[2]=8'h00; exp_bytes[3]=calc_exp_crc(2);
        send_pkt(6);
        check_reply(4, "2b. SEND_STORED to 0x50");

        req_bytes[0]=8'hA5; req_bytes[1]=8'h09; req_bytes[2]=8'h50; req_bytes[3]=8'h00;
        req_bytes[4]=8'h00; req_bytes[5]=calc_req_crc(4);
        exp_bytes[0]=8'h5A; exp_bytes[1]=8'h00; exp_bytes[2]=8'h03; exp_bytes[3]=8'h11;
        exp_bytes[4]=8'h22; exp_bytes[5]=8'h33; exp_bytes[6]=calc_exp_crc(5);
        send_pkt(6);
        check_reply(7, "2c. READ_VERIFY from 0x50");

        u_slave1.mem[1] = 8'hFF;
        req_bytes[0]=8'hA5; req_bytes[1]=8'h09; req_bytes[2]=8'h50; req_bytes[3]=8'h00;
        req_bytes[4]=8'h00; req_bytes[5]=calc_req_crc(4);
        exp_bytes[0]=8'h5A; exp_bytes[1]=8'h08; exp_bytes[2]=8'h03; exp_bytes[3]=8'h11;
        exp_bytes[4]=8'hFF; exp_bytes[5]=8'h33; exp_bytes[6]=calc_exp_crc(5);
        send_pkt(6);
        check_reply(7, "3. Mismatch on READ_VERIFY 0x50");
        u_slave1.mem[1] = 8'h22;

        req_bytes[0]=8'hA5; req_bytes[1]=8'h06; req_bytes[2]=8'h42; req_bytes[3]=8'h00;
        req_bytes[4]=8'h00; req_bytes[5]=calc_req_crc(4);
        exp_bytes[0]=8'h5A; exp_bytes[1]=8'h02; exp_bytes[2]=8'h00; exp_bytes[3]=calc_exp_crc(2);
        send_pkt(6);
        check_reply(4, "4. SEND_STORED to 0x42 (NACK)");

        req_bytes[0]=8'hA5; req_bytes[1]=8'h04; req_bytes[2]=8'h00; req_bytes[3]=8'h00;
        req_bytes[4]=8'h02; req_bytes[5]=8'hAB; req_bytes[6]=8'hCD; req_bytes[7]=calc_req_crc(6) ^ 8'hFF;
        exp_bytes[0]=8'h5A; exp_bytes[1]=8'h01; exp_bytes[2]=8'h00; exp_bytes[3]=calc_exp_crc(2);
        send_pkt(8);
        check_reply(4, "5. Corrupted CRC request");

        req_bytes[0]=8'hA5; req_bytes[1]=8'h07; req_bytes[2]=8'h00; req_bytes[3]=8'h00;
        req_bytes[4]=8'h00; req_bytes[5]=calc_req_crc(4);
        exp_bytes[0]=8'h5A; exp_bytes[1]=8'h00; exp_bytes[2]=8'h00; exp_bytes[3]=calc_exp_crc(2);
        send_pkt(6);
        check_reply(4, "6a. CLEAR");

        req_bytes[0]=8'hA5; req_bytes[1]=8'h05; req_bytes[2]=8'h00; req_bytes[3]=8'h00;
        req_bytes[4]=8'h20;
        for (k = 0; k < 32; k = k + 1) req_bytes[5+k] = 8'hAA;
        req_bytes[37] = calc_req_crc(36);
        exp_bytes[0]=8'h5A; exp_bytes[1]=8'h00; exp_bytes[2]=8'h00; exp_bytes[3]=calc_exp_crc(2);
        send_pkt(38);
        check_reply(4, "6b. STORE 32 bytes");

        req_bytes[0]=8'hA5; req_bytes[1]=8'h05; req_bytes[2]=8'h00; req_bytes[3]=8'h00;
        req_bytes[4]=8'h01; req_bytes[5]=8'h55; req_bytes[6]=calc_req_crc(5);
        exp_bytes[0]=8'h5A; exp_bytes[1]=8'h07; exp_bytes[2]=8'h00; exp_bytes[3]=calc_exp_crc(2);
        send_pkt(7);
        check_reply(4, "6c. STORE 33rd byte (STORE_FULL)");

        rx_count = 0;
        send_byte(8'hA5); send_byte(8'h04); send_byte(8'h00); send_byte(8'h00);
        #10_500_000;
        exp_bytes[0]=8'h5A; exp_bytes[1]=8'h05; exp_bytes[2]=8'h00; exp_bytes[3]=calc_exp_crc(2);
        check_reply(4, "7a. Half packet timeout");

        req_bytes[0]=8'hA5; req_bytes[1]=8'h04; req_bytes[2]=8'h00; req_bytes[3]=8'h00;
        req_bytes[4]=8'h02; req_bytes[5]=8'h12; req_bytes[6]=8'h34; req_bytes[7]=calc_req_crc(6);
        exp_bytes[0]=8'h5A; exp_bytes[1]=8'h00; exp_bytes[2]=8'h02; exp_bytes[3]=8'h12;
        exp_bytes[4]=8'h34; exp_bytes[5]=calc_exp_crc(4);
        send_pkt(8);
        check_reply(6, "7b. Recovery after timeout");

        req_bytes[0]=8'hA5; req_bytes[1]=8'h07; req_bytes[2]=8'h00; req_bytes[3]=8'h00;
        req_bytes[4]=8'h00; req_bytes[5]=calc_req_crc(4);
        send_pkt(6);
        #1_000_000;

        req_bytes[0]=8'hA5; req_bytes[1]=8'h09; req_bytes[2]=8'h50; req_bytes[3]=8'h00;
        req_bytes[4]=8'h00; req_bytes[5]=calc_req_crc(4);
        exp_bytes[0]=8'h5A; exp_bytes[1]=8'h09; exp_bytes[2]=8'h00; exp_bytes[3]=calc_exp_crc(2);
        send_pkt(6);
        check_reply(4, "8. READ_VERIFY when empty");

        req_bytes[0]=8'hA5; req_bytes[1]=8'h05; req_bytes[2]=8'h00; req_bytes[3]=8'h00;
        req_bytes[4]=8'h03; req_bytes[5]=8'h11; req_bytes[6]=8'h22; req_bytes[7]=8'h33; req_bytes[8]=calc_req_crc(7);
        send_pkt(9);
        #1_000_000;

        run_en = 0;
        req_bytes[0]=8'hA5; req_bytes[1]=8'h06; req_bytes[2]=8'h50; req_bytes[3]=8'h00;
        req_bytes[4]=8'h00; req_bytes[5]=calc_req_crc(4);
        send_pkt(6);
        #500_000;
        if (rx_count == 0)
            $display("PASS: 9a. SEND_STORED held while run_en = 0");
        else begin
            $display("FAIL: 9a. Reply received prematurely while run_en = 0");
            test_fail_cnt = test_fail_cnt + 1;
        end

        run_en = 1;
        exp_bytes[0]=8'h5A; exp_bytes[1]=8'h00; exp_bytes[2]=8'h00; exp_bytes[3]=calc_exp_crc(2);
        check_reply(4, "9b. SEND_STORED completes after run_en set to 1");

        #100;
        if (test_fail_cnt == 0)
            $display("\n*** ALL PASS ***\n");
        else
            $display("\n*** FAILED %0d test(s) ***\n", test_fail_cnt);

        $finish;
    end

endmodule