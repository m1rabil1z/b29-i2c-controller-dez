module traffic_fsm #(
    parameter GREEN_T  = 5,
    parameter YELLOW_T = 2
) (
    input            clk,
    input            rst,
    input            tick,
    output reg [2:0] ns_light,
    output reg [2:0] ew_light
);

    parameter [1:0] NS_GREEN = 2'd0,
                    NS_YELLOW = 2'd1,
                    EW_GREEN = 2'd2,
                    EW_YELLOW = 2'd3;

    parameter [2:0] G = 3'd1,
                    Y = 3'd2,
                    R = 3'd4;

    reg [1:0] state, next_state;
    reg [3:0] timer;
    
    always @(posedge clk) begin
        if(rst) begin
            state <= NS_GREEN;
            timer <= 0;
        end    
        else begin
            state <= next_state;
            if(state != next_state) timer <= 0;
            else if (tick) timer <= timer + 1'b1;
        end   
    end

    always @(*) begin
        next_state = state;
        if(tick) begin
        case (state)
            NS_GREEN  : if(timer == GREEN_T-1)  next_state = NS_YELLOW;
            NS_YELLOW : if(timer == YELLOW_T-1) next_state = EW_GREEN;
            EW_GREEN  : if(timer == GREEN_T-1)  next_state = EW_YELLOW;
            EW_YELLOW : if(timer == YELLOW_T-1) next_state = NS_GREEN;
            default : next_state = NS_GREEN; 
        endcase
        end
    end

    always @(*) begin
        case (state)
            NS_GREEN  : begin ns_light = G; ew_light = R; end
            NS_YELLOW : begin ns_light = Y; ew_light = R; end
            EW_GREEN  : begin ns_light = R; ew_light = G; end
            EW_YELLOW : begin ns_light = R; ew_light = Y; end
            default :   begin ns_light = R; ew_light = R; end 
        endcase

    end

endmodule