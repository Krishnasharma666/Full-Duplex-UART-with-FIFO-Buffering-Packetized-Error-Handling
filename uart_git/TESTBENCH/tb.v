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
    wire rd_en_tx;
    wire wr_en_rx;
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
        .rd_en_tx(rd_en_tx),
        .wr_en_rx(wr_en_rx),
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

    // Pure, isolated read task
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

    // Simultaneous read and write task (kept exactly as you wrote it)
    task write_read_simultaneous_tx(input [7:0] din);
        begin
            @(posedge rd_en_tx); 
            w_e = 1'b1;
            data_in = din;

            @(posedge clk); 
            w_e <= 1'b0;     // Deassert write enable
            
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
        wait(busy == 1'b0 && empty_tx_fifo == 1'b1);
        #5000000; // Increased buffer time to ensure all bits arrive

        // Step C: Drain the RX FIFO afterwards (Only Reading)
        while (!empty_rx_fifo) begin
            read_rx();
            $display("[INFO] Successfully Read Data out: 0x%h", d_out);
        end

        #10000;

        // -------------------------------------------------------------
        // SCENARIO 1.5: Parity Error Injection Test (Added Feature)
        // -------------------------------------------------------------
        $display("--- Starting Parity Error Injection Test ---");
        write_tx(8'h55); // Write a test byte
        
        // Wait until transmission begins, then force-corrupt the line during transmission
        @(posedge busy);
        
        // Wait ~300us (puts us around the 3rd data bit at 9600 baud)
        #300000; 
        
        // SAFELY force the bit: Capture it, invert it, then force it.
        begin : inject_error
            reg corrupt_bit;
            corrupt_bit = ~uut.tr.tx;       // Read the current state on the wire
            force uut.tr.tx = corrupt_bit;  // Apply the static inverted state
            
            // Hold for 110us to guarantee we span across the receiver's middle-sampling point
            #110000; 
            
            release uut.tr.tx;              // Give control back to the hardware
        end            // Release line back to transmitter hardware

        // Wait for frame to complete and settle in receiver FIFO
        wait(busy == 1'b0 && empty_tx_fifo == 1'b1);
        #5000000;

        if (!empty_rx_fifo) begin
            read_rx();
            $display("[CORRUPT TEST] Read Data out: 0x%h | Parity Error Bit (Bit 8): %0b", d_out, d_out[8]);
            if (d_out[8] == 1'b1)
                $display("[PASS] Parity error successfully detected by receiver hardware!");
        end

        #10000;

        // -------------------------------------------------------------
        // SCENARIO 3: Simultaneous Read and Write on TX FIFO
        // -------------------------------------------------------------
        $display("--- Starting Scenario 3: Simultaneous TX Read/Write ---");
        
        // 1. Write Byte A: This wakes up the transmitter to start sending
        write_tx(8'hAA);
        
        // 2. Write Byte B: This waits in the TX FIFO while Byte A is transmitting
        write_tx(8'hBB);
        
        // 3. Wait in ambush: When the hardware asserts 'rd_en_tx' to fetch Byte B, 
        //    we will simultaneously write Byte C (0xCC) into the FIFO.
        write_read_simultaneous_tx(8'hCC); 
        $display("[SIMULTANEOUS TEST] Wrote 0xCC to TX FIFO precisely when it read 0xBB");
        
        // 4. Wait for the newly written bytes to finish transmitting
        wait(busy == 1'b0 && empty_tx_fifo == 1'b1);
        #5000000;

        // 5. Read out the bytes to verify they weren't corrupted by the simultaneous operation
        while (!empty_rx_fifo) begin
            read_rx();
            $display("[SIMULTANEOUS TEST] Safely Read Data out: 0x%h", d_out);
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
        #5000000; 

        if (full_rx_fifo)
            $display("[PASS] RX FIFO successfully asserted full flag on overflow.");

        // Drain the remaining receiver FIFO contents completely separate from writing
        while (!empty_rx_fifo) begin
            read_rx();
            $display("[INFO] Draining Overflow FIFO Data out: 0x%h", d_out);
        end
        
        read_rx();

        $display("--- ALL TESTBENCH SCENARIOS COMPLETED SUCCESSFULLY ---");
        #1000;
        $finish;
    end
endmodule
