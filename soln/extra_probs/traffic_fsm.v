module traffic_fsm #(
    parameter GREEN_T  = 5,       // green ke ticks
    parameter YELLOW_T = 2        // yellow ke ticks
) (
    input        clk,
    input        rst,             // synchronous reset, NS_GREEN pe jaata hai
    input        tick,            // slow pulse (C3 se ya testbench se)
    output reg [2:0] ns_light,        // {R, Y, G} one-hot
    output reg [2:0] ew_light         // {R, Y, G} one-hot
);

    parameter NS_GREEN = 0, NS_YELLOW = 1, EW_GREEN = 2, EW_YELLOW = 3;
    reg [1:0]state, next_state;
    reg [2:0]count;

    always @(posedge clk) begin
        if (rst) begin
            state <= NS_GREEN;
            count <= 0;
        end else begin
            state <= next_state;
            if (state != next_state) begin
                count <= 0;
            end else if (tick) begin
                count <= count + 1;
            end
        end

    end

    always @(*) begin
        next_state = state;
        case (state)
            NS_GREEN: if (tick && count == GREEN_T - 1) next_state = NS_YELLOW;
            NS_YELLOW: if (tick && count == YELLOW_T - 1) next_state = EW_GREEN;
            EW_GREEN: if (tick && count == GREEN_T - 1) next_state = EW_YELLOW;
            EW_YELLOW: if (tick && count == YELLOW_T - 1) next_state = NS_GREEN;
        endcase
    end

    always @(*) begin
        case (state)
            NS_GREEN: begin
                ns_light = 3'b001;
                ew_light = 3'b100;    
            end
            NS_YELLOW: begin
                ns_light = 3'b010;
                ew_light = 3'b100;     
            end
            EW_GREEN: begin
                ns_light = 3'b100;
                ew_light = 3'b001;
            end
            EW_YELLOW: begin
                ns_light = 3'b100;
                ew_light = 3'b010;
            end
            default: begin
                ns_light = 3'b100;
                ew_light = 3'10;
            end
        endcase  
    end

endmodule