module receiver(
    input clk,
    input reset_n,
    input ready_clr,
    input rx,
    input rx_e,
    input full_rx_fifo,
    output reg rdy,
    output reg [8:0] d_out_rx,
    output reg wr_en_rx
);

reg [7:0] register;
parameter [2:0] start = 3'b000;
parameter [2:0] dataread = 3'b001;
parameter [2:0] par = 3'b010;
parameter [2:0] data_to_fifo = 3'b011;
parameter [2:0] stop = 3'b100;

reg [2:0] state;
reg [3:0] sample;
reg [2:0] index;
reg error;

always @(posedge clk) begin
    if(!reset_n) begin
        rdy <= 1'b0;
        state <= start;
        d_out_rx <= 9'h000;
        register <= 8'h00;
        sample <= 4'h0;
        index <= 3'b000;
        wr_en_rx <= 0;
        error <= 0;
    end else begin
        if(ready_clr)
            rdy <= 1'b0;
            
        case(state)
            start: begin
                wr_en_rx <= 0;
                if(rx_e) begin
                    if(rx == 1'b0) begin
                        if(sample == 15) begin
                            sample <= 4'b0000;
                            state <= dataread;
                        end else begin
                            sample <= sample + 1'b1;
                        end
                    end else begin
                        sample <= 4'b0000; 
                    end
                end
            end
            dataread: begin
                wr_en_rx <= 0;
                if(rx_e) begin
                    if(sample == 4'b1000) begin
                        register[index] <= rx;
                        sample <= sample + 1'b1;
                    end else if((sample == 4'b1111) && (index == 3'b111)) begin
                        state <= par;
                        sample <= 4'b0000;
                    end else if(sample == 4'b1111) begin
                        sample <= 4'b0000;
                        index <= index + 1'b1;
                    end else begin
                        sample <= sample + 1'b1;
                    end
                end
            end
            par: begin
                wr_en_rx <= 0;
                if(rx_e) begin
                    if(sample == 4'b1000) begin
                        error <= (^register) ^ rx;
                        sample <= sample + 1'b1;
                    end else if(sample == 4'b1111) begin
                        state <= stop;
                        sample <= 4'b0000;
                    end else begin
                        sample <= sample + 1'b1;
                    end
                end
            end
            stop: begin
                wr_en_rx <= 0;
                if(rx_e) begin
                    if(rx == 1'b1) begin
                        if(!full_rx_fifo) begin
                            if(sample == 15) begin
                                sample <= 4'b0000;
                                state <= data_to_fifo;
                                d_out_rx <= {error, register};
                                wr_en_rx <= 1;
                                rdy <= 1'b1;
                                index <= 3'b000;
                            end else begin
                                sample <= sample + 1'b1;
                            end
                        end
                    end
                end
            end
            data_to_fifo: begin
                wr_en_rx <= 0;
                if(rx_e) 
                    state <= start;
            end
            default: begin
                state <= start;
                wr_en_rx <= 0;
            end
        endcase
    end
end

endmodule