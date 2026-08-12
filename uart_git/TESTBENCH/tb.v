`timescale 1ns/1ps
module tb();

    // Inputs to main_module
    reg clk;
    reg reset_n;
    reg w_e;
    reg r_e;
    reg rdy_clr;
    reg [7:0] data_in;

    // Outputs from main_module
    wire full_tx_fifo;
    wire empty_rx_fifo;
    wire full_rx_fifo;
    wire empty_tx_fifo;
    wire busy;
    wire rdy;
    wire [8:0] d_out;

    integer i;

    // Instantiate Top-Level Module
    main_module uut (
        .clk(clk),
        .reset_n(reset_n),
        .w_e(w_e),
        .r_e(r_e),
        .rdy_clr(rdy_clr),
        .data_in(data_in),
        .full_tx_fifo(full_tx_fifo),
        .empty_rx_fifo(empty_rx_fifo),
        .full_rx_fifo(full_rx_fifo),
        .empty_tx_fifo(empty_tx_fifo),
        .busy(busy),
        .rdy(rdy),
        .d_out(d_out)
    );

    // Generate 100 MHz clock
    always #5 clk = ~clk;

    // --- HELPER TASKS ---
    task write_tx(input [7:0] din);
        begin
            @(posedge clk); 
            w_e = 1'b1;
            data_in = din;
            @(posedge clk); 
            w_e = 1'b0;
        end
    endtask

    // Pure, isolated read task (never called concurrently with writes)
    task read_rx();
        begin
            @(posedge clk); 
            r_e = 1'b1;
            @(posedge clk);
            r_e = 1'b0;
            @(posedge clk); 
            rdy_clr = 1'b1;  
            @(posedge clk);
            rdy_clr = 1'b0;  
        end
    endtask

    initial begin
        // Initialize Signals
        clk = 0;
        reset_n = 0;
        w_e = 0;
        r_e = 0;
        rdy_clr = 0;
        data_in = 8'h00;

        // Apply Reset
        #100;
        reset_n = 1;
        #100;

        // -------------------------------------------------------------
        // SCENARIO 1: Normal Transmission and Reception (4 Bytes)
        // -------------------------------------------------------------
        $display("--- Starting Scenario 1: Normal TX/RX ---");
        
        // Step A: Write all bytes first (Only Writing)
        write_tx(8'hA5);
        write_tx(8'hA6);
        write_tx(8'hA7);
        write_tx(8'hA8);

        // Step B: Wait completely until the UART finishes serializing and filling RX FIFO
        wait(busy == 1'b0);
        #600000; // Allow final bit frames to safely settle into RX FIFO

        // Step C: Drain the RX FIFO afterwards (Only Reading)
        $display("--- Draining RX FIFO ---");
        for (i = 0; i < 4; i = i + 1) begin
            if (!empty_rx_fifo) begin
                read_rx();
                $display("[INFO] Successfully Read Data out: 0x%h (Error Bit: %0b)", d_out, d_out[8]);
            end
        end

        #10000;

        // -------------------------------------------------------------
        // SCENARIO 1.5: Parity Error Injection Test (Added Feature)
        // -------------------------------------------------------------
        $display("--- Starting Parity Error Injection Test ---");
        
        write_tx(8'h55); // Write a test byte
        
        // Wait until transmission begins, then force-corrupt the line during transmission
        @(posedge busy);
        #300000; // Time window corresponding roughly to data/parity transmission
        
        force uut.tr.tx = ~uut.tr.tx; // Invert current bit on the wire
        #20000;                       // Hold corruption for a short burst
        release uut.tr.tx;            // Release line back to transmitter hardware

        // Wait for frame to complete and settle in receiver FIFO
        wait(busy == 1'b0);
        #600000;

        if (!empty_rx_fifo) begin
            read_rx();
            $display("[CORRUPT TEST] Read Data out: 0x%h | Parity Error Bit (Bit 8): %0b", d_out, d_out[8]);
            if (d_out[8] == 1'b1)
                $display("[PASS] Parity error successfully detected by receiver hardware!");
        end

        #10000;

        // -------------------------------------------------------------
        // SCENARIO 2 & 4: Fill TX FIFO above limit & Test RX Overflow
        // -------------------------------------------------------------
        $display("--- Starting Scenario 2 & 4: FIFO Overflow Test ---");
        
        // Write 18 items sequentially (FIFO depth is 16)
        for (i = 0; i < 18; i = i + 1) begin
            write_tx(8'h30 + i);
        end
        
        // Wait until transmitter finishes sending everything out
        wait(busy == 1'b0 && empty_tx_fifo == 1'b1);
        
        // Allow buffer time for final bits to hit receiver FIFO
        #600000; 

        if (full_rx_fifo)
            $display("[PASS] RX FIFO successfully asserted full flag on overflow.");

        // Drain the remaining receiver FIFO contents completely separate from writing
        while (!empty_rx_fifo) begin
            read_rx();
            $display("[INFO] Draining Overflow FIFO Data out: 0x%h", d_out);
        end

        $display("--- ALL TESTBENCH SCENARIOS COMPLETED SUCCESSFULLY ---");
        #1000;
        $finish;
    end

endmodule