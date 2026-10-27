`timescale 1ns/1ps
module i2c_slave_model #(
    parameter [6:0] ADDR = 7'h50
)(
    input  wire scl,
    input  wire sda,
    output reg  scl_low,
    output reg  sda_low
);
    reg [7:0] mem [0:255];
    reg [7:0] ptr;
    reg [7:0] b;
    reg       got_start;
    reg       master_ack;
    integer   stretch_ns;
    integer   i;
    initial begin
        scl_low    = 0;
        sda_low    = 0;
        got_start  = 0;
        ptr        = 0;
        stretch_ns = 0;
        for (i = 0; i < 256; i = i + 1) mem[i] = 8'h00;
    end
    always @(negedge sda) if (scl === 1'b1) begin
        got_start = 1;
        disable fsm;
    end
    always @(posedge sda) if (scl === 1'b1) begin
        got_start = 0;
        disable fsm;
    end
    task recv_byte;
        integer n;
        begin
            for (n = 0; n < 8; n = n + 1) begin
                @(posedge scl);
                b = {b[6:0], sda};
            end
        end
    endtask
    task ack_bit;
        begin
            @(negedge scl);
            #100 sda_low = 1;
            if (stretch_ns > 0) begin
                scl_low = 1;
                #(stretch_ns);
                scl_low = 0;
            end
        end
    endtask
    task send_byte;
        input [7:0] d;
        integer n;
        begin
            for (n = 7; n >= 0; n = n - 1) begin
                @(negedge scl);
                #100 sda_low = ~d[n];
            end
            @(negedge scl);
            #100 sda_low = 0;
            @(posedge scl);
            master_ack = ~sda;
        end
    endtask
    always begin : fsm
        sda_low = 0;
        scl_low = 0;
        wait (got_start);
        got_start = 0;
        recv_byte;
        if (b[7:1] != ADDR)
            forever @(posedge scl);
        ack_bit;
        if (b[0] == 1'b0) begin
            @(negedge scl); #100 sda_low = 0;
            recv_byte;
            ptr = b;
            ack_bit;
            forever begin
                @(negedge scl); #100 sda_low = 0;
                recv_byte;
                mem[ptr] = b;
                ptr = ptr + 1;
                ack_bit;
            end
        end else begin
            master_ack = 1;
            while (master_ack) begin
                send_byte(mem[ptr]);
                ptr = ptr + 1;
            end
            forever @(posedge scl);
        end
    end
endmodule
