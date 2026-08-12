module transmitter(
    input clk,
    input reset_n,
    input tx_e,
    input empty_tx_fifo,
    input [7:0] d_in_tx,
    output reg tx,
    output busy,
    output reg rd_en_tx
);

parameter idle = 3'b000;
parameter start = 3'b001;
parameter data = 3'b010;
parameter par = 3'b011;
parameter stop1 = 3'b100;
parameter stop2 = 3'b101;

reg [2:0] state;
reg [2:0] index; 

always @(posedge clk) begin
    if(!reset_n) begin
        state <= idle;
        tx <= 1'b1;
        rd_en_tx <= 0;
        index <= 3'b000;
    end else begin
        case(state)
            idle: begin 
                rd_en_tx <= 0;
                if(!empty_tx_fifo) begin
                    state <= start;
                    index <= 3'b000;
                    rd_en_tx <= 1;
                end
            end
            start: begin
                rd_en_tx <= 0;
                if(tx_e) begin
                    tx <= 1'b0;
                    state <= data;
                end
            end     
            data: begin
                rd_en_tx <= 0;
                if (tx_e) begin
                    tx <= d_in_tx[index]; 
                    if (index == 3'b111)
                        state <= par; 
                    else
                        index <= index + 1; 
                end
            end
            par: begin
                rd_en_tx <= 0;
                if (tx_e) begin
                    tx <= ^d_in_tx;
                    state <= stop1;
                end
            end
            stop1: begin
                rd_en_tx <= 0;
                if(tx_e) begin
                    tx <= 1'b1;
                    state <= stop2;
                end
            end
            stop2: begin
                rd_en_tx <= 0;
                if(tx_e) begin
                    tx <= 1'b1;
                    state <= idle;
                end
            end
            default: begin
                tx <= 1'b1;
                state <= idle;
                rd_en_tx <= 0;
            end
        endcase
    end
end

assign busy = (state != idle) ? 1 : 0;

endmodule