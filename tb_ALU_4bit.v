`timescale 1ns / 1ps

module tb_ALU_4bit;

    reg [3:0] A;
    reg [3:0] B;
    reg [1:0] select;

    wire [3:0] ans;
    wire c_out;

    alu_4bit uut (
        .A(A),
        .B(B),
        .select(select),
        .ans(ans),
        .c_out(c_out)
    );

    initial begin
        $dumpfile("alu_waveform.vcd");
        $dumpvars(0, tb_ALU_4bit);

        $monitor("Time=%0t | A=%b | B=%b | Sel=%b | Ans=%b | Cout=%b", 
                 $time, A, B, select, ans, c_out);

        A = 4'b0101; B = 4'b0011; select = 2'b00; #10;
        A = 4'b1111; B = 4'b0010; select = 2'b00; #10;
        A = 4'b0111; B = 4'b0100; select = 2'b01; #10;
        A = 4'b1100; B = 4'b1010; select = 2'b10; #10;
        A = 4'b1100; B = 4'b1010; select = 2'b11; #10;

        $finish;
    end

endmodule