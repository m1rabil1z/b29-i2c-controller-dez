`timescale 1ns/1ps
// i2c_slave_model.v
//
// Behavioural I2C slave, simulation only (NOT synthesisable).
// Stand-in until Neer's real slave is ready. Same register idea:
//   write: [addr+W] [reg] [data] [data] ...  -> mem[reg], reg++
//   read:  [addr+R] -> sends mem[reg], reg++ until the master NACKs
//
// stretch_ns: if not 0, holds SCL low that long after every byte it
// receives (before its ACK). Set from the testbench:
//   slave0.stretch_ns = 8000;

module i2c_slave_model #(
    parameter [6:0] ADDR = 7'h50
)(
    input  wire scl,       // bus levels
    input  wire sda,
    output reg  scl_low,   // 1 = we pull the line low
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

    // START = SDA falls while SCL high, STOP = SDA rises while SCL high.
    // Either one kills whatever the slave was doing and restarts fsm.
    always @(negedge sda) if (scl === 1'b1) begin
        got_start = 1;
        disable fsm;
    end
    always @(posedge sda) if (scl === 1'b1) begin
        got_start = 0;
        disable fsm;
    end

    // 8 bits MSB first, sampled on SCL rising edge
    task recv_byte;
        integer n;
        begin
            for (n = 0; n < 8; n = n + 1) begin
                @(posedge scl);
                b = {b[6:0], sda};
            end
        end
    endtask

    // ACK: pull SDA low for the 9th clock. Stretch first if asked.
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

    // we're being read: put a byte on SDA, bits change 100 ns after SCL falls
    task send_byte;
        input [7:0] d;
        integer n;
        begin
            for (n = 7; n >= 0; n = n - 1) begin
                @(negedge scl);
                #100 sda_low = ~d[n];
            end
            @(negedge scl);
            #100 sda_low = 0;        // let go, master ACKs/NACKs now
            @(posedge scl);
            master_ack = ~sda;
        end
    endtask

    always begin : fsm
        sda_low = 0;
        scl_low = 0;
        wait (got_start);
        got_start = 0;

        recv_byte;                       // address + R/W
        if (b[7:1] != ADDR)
            forever @(posedge scl);      // not us, sit here till next START/STOP

        ack_bit;
        if (b[0] == 1'b0) begin
            // master writing, first byte = register pointer
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
            // master reading
            master_ack = 1;
            while (master_ack) begin
                send_byte(mem[ptr]);
                ptr = ptr + 1;
            end
            forever @(posedge scl);      // NACKed, wait for STOP / repeated START
        end
    end

endmodule