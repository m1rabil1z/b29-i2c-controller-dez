module top_module(
    input  [3:0] a,        // operand A
    input  [3:0] b,        // operand B
    input  [1:0] op,       // 00 add, 01 sub, 10 and, 11 or
    output [3:0] y,        // result
    output cout,     // carry (add) / borrow (sub)
    output zero      // 1 jab y == 0
);

    wire [3:0] add_y, sub_y;
    wire add_cout, sub_cout;

    add4 inst_add(a, b, 1'b0, add_y, add_cout);
    add4 inst_sub(a, ~b, 1'b1, sub_y, sub_cout);

    always @(*) begin
        case(op)
            2'b00:begin
                y = add_y; 
                cout = add_cout;
            end
            2'b01: begin
                y = sub_y; 
                cout = sub_cout;
            end
            2'b10: begin
                y = a & b; 
                cout = 0;
            end
            2'b11: begin
                y = a | b; 
                cout = 0;
            end
        endcase

        zero = (y == 0);
    end
endmodule


module add1 ( input a, input b, input cin,   output sum, output cout );
    assign sum = (a ^ b ^ cin);
    assign cout = a&b | a&cin | b&cin;
endmodule


module add4 ( input [3:0]a, input [3:0]b, input cin,   output reg [3:0]sum, output cout );

    wire cout0;
    wire cout1;
    wire cout2;

    add1 instance1(a[0], b[0], cin, sum[0], cout0);
    add1 instance2(a[1], b[1], cout0, sum[1], cout1);
    add1 instance3(a[2], b[2], cout1, sum[2], cout2);
    add1 instance4(a[3], b[3], cout2, sum[3], cout);
    
    
endmodule


