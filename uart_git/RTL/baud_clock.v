module baud_clock(
    input clk,
    output reg tx_e,
    output reg rx_e
);

reg [8:0] counter_rx;
reg [3:0] tick_counter; 

initial begin
    counter_rx = 0;
    tick_counter = 0;
    tx_e = 0;
    rx_e = 0;
end

always @(posedge clk) begin
    if(counter_rx == 9'd325) begin 
        counter_rx <= 0;
        rx_e <= 1'b1;
        tick_counter <= tick_counter + 1;
        if (tick_counter == 4'd15)
            tx_e <= 1'b1;
        else
            tx_e <= 1'b0;
    end else begin
        counter_rx <= counter_rx + 1;
        rx_e <= 1'b0;
        tx_e <= 1'b0;
    end
end

endmodule
