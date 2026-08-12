module main_module(
    input clk,
    input reset_n,
    input w_e,
    input r_e,
    input rdy_clr,
    input [7:0] data_in,
    output full_tx_fifo,
    output empty_rx_fifo,
    output full_rx_fifo,
    output empty_tx_fifo,
    output busy,
    output rdy,
    output [8:0] d_out
);

wire tx_en;
wire rx_en;
wire tx_temp;
wire rd_en_tx;
wire wr_en_rx;
wire [7:0] d_in_tx;
wire [8:0] d_out_rx;

baud_clock bg(clk, tx_en, rx_en);

transmitter tr(
    .clk(clk),
    .reset_n(reset_n),
    .tx_e(tx_en),
    .empty_tx_fifo(empty_tx_fifo),
    .d_in_tx(d_in_tx),
    .tx(tx_temp),
    .busy(busy),
    .rd_en_tx(rd_en_tx)
);

rx_fifo #(.WIDTH(8)) fifo_tx(
    .clk(clk),
    .reset_n(reset_n),
    .wr_en(w_e),
    .rd_en(rd_en_tx),
    .data_in(data_in),
    .data_out(d_in_tx),
    .empty(empty_tx_fifo),
    .full(full_tx_fifo)
);

receiver rc(
    .clk(clk),
    .reset_n(reset_n),
    .ready_clr(rdy_clr),
    .rx(tx_temp),
    .rx_e(rx_en),
    .full_rx_fifo(full_rx_fifo),
    .rdy(rdy),
    .d_out_rx(d_out_rx),
    .wr_en_rx(wr_en_rx)
);

rx_fifo #(.WIDTH(9)) fifo_rx(
    .clk(clk),
    .reset_n(reset_n),
    .wr_en(wr_en_rx),
    .rd_en(r_e),
    .data_in(d_out_rx),
    .data_out(d_out),
    .empty(empty_rx_fifo),
    .full(full_rx_fifo)
);

endmodule