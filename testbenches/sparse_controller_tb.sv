// =============================================================================
// Testbench   : tb_sparse_controller
// Description : Verifies sparse_controller at 5 sparsity levels.
//               Checks row_en correctness and confirms zero-weight rows
//               produce no enable transitions (waveform visible in GTKWave).
// =============================================================================

`timescale 1ns/1ps

module tb_sparse_controller;

    // ─── Parameters matching DUT ──────────────────────────────────────────────
    localparam int N_ROWS    = 128;
    localparam int IDX_WIDTH = 7;
    localparam int MAX_NNZ   = 128;
    localparam int CLK_PERIOD = 20;     // 50 MHz → 20 ns period

    // ─── DUT signals ──────────────────────────────────────────────────────────
    logic                          clk;
    logic                          rst;
    logic                          start;
    logic [$clog2(MAX_NNZ)-1:0]    nnz_count;
    logic [$clog2(MAX_NNZ)-1:0]    idx_addr;
    logic [IDX_WIDTH-1:0]          idx_data;
    logic [N_ROWS-1:0]             row_en;
    logic                          valid;
    logic                          done;

    // ─── BRAM model ───────────────────────────────────────────────────────────
    // Simulates 1-cycle read latency — just like real FPGA BRAM
    logic [IDX_WIDTH-1:0] bram_mem [0:MAX_NNZ-1];

    always_ff @(posedge clk)
        idx_data <= bram_mem[idx_addr];     // 1-cycle registered read

    // ─── DUT instantiation ────────────────────────────────────────────────────
    sparse_controller #(
        .N_ROWS    (N_ROWS),
        .IDX_WIDTH (IDX_WIDTH),
        .MAX_NNZ   (MAX_NNZ)
    ) dut (
        .clk       (clk),
        .rst       (rst),
        .start     (start),
        .nnz_count (nnz_count),
        .idx_addr  (idx_addr),
        .idx_data  (idx_data),
        .row_en    (row_en),
        .valid     (valid),
        .done      (done)
    );

    // ─── Clock generation ─────────────────────────────────────────────────────
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ─── Task: load BRAM with a set of indices ─────────────────────────────────
    task automatic load_bram(input logic [IDX_WIDTH-1:0] indices[],
                             input int count);
        for (int i = 0; i < count; i++)
            bram_mem[i] = indices[i];
    endtask

    // ─── Task: run one dispatch and check row_en ───────────────────────────────
    task automatic run_and_check(
        input string          test_name,
        input logic [IDX_WIDTH-1:0] expected_indices[],
        input int             nnz
    );
        logic [N_ROWS-1:0] expected_row_en;
        int timeout;

        // Build expected row_en from index list
        expected_row_en = '0;
        for (int i = 0; i < nnz; i++)
            expected_row_en[expected_indices[i]] = 1'b1;

        // Drive inputs
        nnz_count = nnz;
        @(posedge clk); #1;
        start = 1'b1;
        @(posedge clk); #1;
        start = 1'b0;

        // Wait for done with timeout
        timeout = 0;
        while (!done && timeout < (nnz * 4 + 20)) begin
            @(posedge clk);
            timeout++;
        end

        // Allow one more cycle for done to propagate
        @(posedge clk); #1;

        // Check result
        if (row_en === expected_row_en) begin
            $display("PASS  [%s]  nnz=%0d  row_en correct", test_name, nnz);
        end else begin
            $display("FAIL  [%s]  nnz=%0d", test_name, nnz);
            $display("  Expected: %b", expected_row_en);
            $display("  Got     : %b", row_en);
        end

        // Check done pulsed (not stuck high)
        @(posedge clk);
        if (done)
            $display("WARN  [%s]  done stayed high for >1 cycle", test_name);

        // Small gap between tests
        repeat(5) @(posedge clk);
    endtask

    // ─── Main test sequence ───────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_sparse_controller.vcd");
        $dumpvars(0, tb_sparse_controller);

        // Initialise
        rst       = 1'b1;
        start     = 1'b0;
        nnz_count = '0;
        repeat(4) @(posedge clk);
        rst = 1'b0;
        repeat(2) @(posedge clk);

        $display("========================================");
        $display("  Sparse Controller Testbench");
        $display("========================================");

        // ── Test 1: 0% sparsity — all 128 rows active ─────────────────────
        begin
            logic [IDX_WIDTH-1:0] idx_all[128];
            for (int i = 0; i < 128; i++) idx_all[i] = i[IDX_WIDTH-1:0];
            load_bram(idx_all, 128);
            run_and_check("0pct_sparse_all_active", idx_all, 128);
        end

        // ── Test 2: 25% sparsity — 96 non-zero rows ───────────────────────
        begin
            logic [IDX_WIDTH-1:0] idx_75[96];
            int k = 0;
            // Every 4th row is zero — skip rows 3,7,11,15...
            for (int i = 0; i < 128; i++) begin
                if ((i % 4) != 3) begin
                    idx_75[k] = i[IDX_WIDTH-1:0];
                    k++;
                end
            end
            load_bram(idx_75, 96);
            run_and_check("25pct_sparse", idx_75, 96);
        end

        // ── Test 3: 50% sparsity — 64 non-zero rows ───────────────────────
        begin
            logic [IDX_WIDTH-1:0] idx_50[64];
            for (int i = 0; i < 64; i++)
                idx_50[i] = (i * 2)[IDX_WIDTH-1:0];   // even rows only
            load_bram(idx_50, 64);
            run_and_check("50pct_sparse_even_rows", idx_50, 64);
        end

        // ── Test 4: 75% sparsity — 32 non-zero rows ───────────────────────
        begin
            logic [IDX_WIDTH-1:0] idx_25[32];
            for (int i = 0; i < 32; i++)
                idx_25[i] = (i * 4)[IDX_WIDTH-1:0];   // every 4th row
            load_bram(idx_25, 32);
            run_and_check("75pct_sparse", idx_25, 32);
        end

        // ── Test 5: 90% sparsity — 13 non-zero rows ───────────────────────
        begin
            logic [IDX_WIDTH-1:0] idx_10[13];
            idx_10 = '{7'd2, 7'd11, 7'd19, 7'd34, 7'd47,
                       7'd58, 7'd63, 7'd71, 7'd88, 7'd99,
                       7'd107, 7'd115, 7'd126};
            load_bram(idx_10, 13);
            run_and_check("90pct_sparse", idx_10, 13);
        end

        // ── Test 6: Single non-zero weight ────────────────────────────────
        begin
            logic [IDX_WIDTH-1:0] idx_one[1];
            idx_one[0] = 7'd42;
            load_bram(idx_one, 1);
            run_and_check("single_nonzero_row42", idx_one, 1);
        end

        // ── Test 7: Back-to-back starts (no manual reset between) ─────────
        begin
            logic [IDX_WIDTH-1:0] idx_a[4];
            logic [IDX_WIDTH-1:0] idx_b[3];
            idx_a = '{7'd10, 7'd20, 7'd30, 7'd40};
            idx_b = '{7'd5,  7'd55, 7'd105};

            load_bram(idx_a, 4);
            nnz_count = 4;
            @(posedge clk); #1;
            start = 1'b1;
            @(posedge clk); #1;
            start = 1'b0;
            // Wait for done
            while (!done) @(posedge clk);
            @(posedge clk);

            // Immediately start another dispatch
            load_bram(idx_b, 3);
            run_and_check("back_to_back_second", idx_b, 3);
        end

        $display("========================================");
        $display("  All tests complete.");
        $display("========================================");

        $finish;
    end

    // ─── Timeout watchdog ─────────────────────────────────────────────────────
    initial begin
        #500000;
        $display("TIMEOUT — simulation exceeded limit");
        $finish;
    end

endmodule