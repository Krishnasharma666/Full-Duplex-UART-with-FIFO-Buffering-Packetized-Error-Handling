module rx_fifo
#(parameter WIDTH = 8)(
    input clk,
    input reset_n,
    input wr_en,
    input rd_en,
    input [WIDTH - 1:0] data_in,
    output reg [WIDTH - 1:0] data_out,
    output empty,
    output full
);

reg [WIDTH - 1:0] mem [15:0];
reg [3:0] rear, front;
reg [4:0] counter;
wire [3:0] temp;

assign temp = rear + 1;
assign full = (counter == 16);
assign empty = (counter == 0);

always @(posedge clk) begin
    if(!reset_n) begin
        counter <= 0;
        front <= 0;
        rear <= 15;
        data_out <= 0;
    end else begin
        if(rd_en && wr_en) begin
            mem[temp] <= data_in;
            rear <= temp;
            data_out <= mem[front];
            front <= front + 1;
        end
        else if(!rd_en && wr_en) begin
            if(!full) begin
                mem[temp] <= data_in;
                rear <= temp;
                counter <= counter + 1;
            end
        end
        else if(!wr_en && rd_en) begin
            if(!empty) begin
                data_out <= mem[front];
                front <= front + 1;
                counter <= counter - 1;
            end
        end
    end
end

endmodule
