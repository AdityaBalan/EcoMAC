// =============================================================================
// Testbench   : tb_cim_array
// Description : Loads known INT8 weights, applies test activations, and
//               compares col_acc outputs against a software golden reference
//               computed identically inside this testbench.
//               Tests: dense (0% sparsity), 50% sparse, 90% sparse,
//               all-zero activation, max-value stress, sign correctness.
// =============================================================================

`timescale 1ns/1ps

module tb_cim_array;

    // ─── Parameters ───────────────────────────────────────────────────────────
    localparam int N_ROWS      = 128;
    localparam int N_COLS      = 10;
    localparam int DATA_WIDTH  = 8;
    localparam int APPROX_BITS = 4;
    localparam int CLK_PERIOD  = 20;    // 50 MHz

    // ─── DUT signals ──────────────────────────────────────────────────────────
    logic                         clk, rst;
    logic signed [DATA_WIDTH-1:0] input_act;
    logic [N_ROWS-1:0]            row_en;
    logic                         acc_clear;
    logic signed [31:0]           col_acc [0:N_COLS-1];
    logic                         acc_valid;

    // ─── DUT instantiation ────────────────────────────────────────────────────
    cim_array #(
        .N_ROWS      (N_ROWS),
        .N_COLS      (N_COLS),
        .DATA_WIDTH  (DATA_WIDTH),
        .APPROX_BITS (APPROX_BITS)
    ) dut (
        .clk       (clk),
        .rst       (rst),
        .input_act (input_act),
        .row_en    (row_en),
        .acc_clear (acc_clear),
        .col_acc   (col_acc),
        .acc_valid (acc_valid)
    );

    // ─── Clock ────────────────────────────────────────────────────────────────
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ─── Weight and golden reference storage ──────────────────────────────────
    logic signed [DATA_WIDTH-1:0] test_weights [0:N_ROWS-1];
    logic signed [31:0]           golden_acc   [0:N_COLS-1];

    // ─── Approximate multiplier model (pure function for golden reference) ─────
    // Mirrors the hardware LOA logic exactly so golden reference includes
    // approximation error — we're not checking against exact math,
    // we're checking that hardware matches the RTL model bit-for-bit.

    function automatic logic signed [15:0] approx_mult_model(
        input logic signed [7:0] a,
        input logic signed [7:0] b
    );
        logic        sign_a, sign_b, sign_out;
        logic [7:0]  mag_a, mag_b;
        logic [15:0] pp_shifted [0:7];
        logic [15:0] mag_exact;
        logic [3:0]  approx_lower;
        logic [15:0] mag_approx;
        logic [7:0]  pp_row [0:7];

        sign_a   = a[7];
        sign_b   = b[7];
        sign_out = sign_a ^ sign_b;
        mag_a    = sign_a ? (~a + 1'b1) : a;
        mag_b    = sign_b ? (~b + 1'b1) : b;

        // Generate partial products
        for (int ii = 0; ii < 8; ii++)
            pp_row[ii] = mag_a & {8{mag_b[ii]}};

        // Shifted partial products
        for (int ii = 0; ii < 8; ii++)
            pp_shifted[ii] = {8'b0, pp_row[ii]} << ii;

        // Exact sum
        mag_exact = '0;
        for (int ii = 0; ii < 8; ii++)
            mag_exact += pp_shifted[ii];

        // LOA lower bits
        for (int col = 0; col < APPROX_BITS; col++) begin
            logic [7:0] col_bits;
            col_bits = '0;
            for (int row = 0; row <= col; row++) begin
                int pp_bit;
                pp_bit = col - row;
                if (pp_bit >= 0 && pp_bit < 8)
                    col_bits[row] = pp_row[row][pp_bit];
            end
            approx_lower[col] = |col_bits;
        end

        mag_approx = mag_exact;
        mag_approx[APPROX_BITS-1:0] = approx_lower;

        return sign_out ? -(16)'(mag_approx) : (16)'(mag_approx);
    endfunction

    // ─── Task: compute golden accumulation for given weights, act, row_en ─────
    task automatic compute_golden(
        input logic signed [7:0]  weights [0:N_ROWS-1],
        input logic signed [7:0]  act,
        input logic [N_ROWS-1:0]  en
    );
        for (int c = 0; c < N_COLS; c++)
            golden_acc[c] = '0;

        for (int rr = 0; rr < N_ROWS; rr++) begin
            if (en[rr]) begin
                automatic logic signed [15:0] prod;
                prod = approx_mult_model(weights[rr], act);
                golden_acc[rr % N_COLS] += {{16{prod[15]}}, prod};
            end
        end
    endtask

    // ─── Task: run one activation through array and check ─────────────────────
    task automatic run_test(
        input string              test_name,
        input logic signed [7:0]  act,
        input logic [N_ROWS-1:0]  en
    );
        int mismatches;
        mismatches = 0;

        // Clear accumulators
        acc_clear = 1'b1;
        @(posedge clk); #1;
        acc_clear = 1'b0;
        @(posedge clk); #1;

        // Present inputs
        input_act = act;
        row_en    = en;
        @(posedge clk); #1;     // one clock for accumulation

        // Deassert enables
        row_en = '0;
        @(posedge clk); #1;

        // Compute golden reference
        compute_golden(test_weights, act, en);

        // Compare
        for (int c = 0; c < N_COLS; c++) begin
            if (col_acc[c] !== golden_acc[c]) begin
                $display("  MISMATCH col[%0d]: got %0d, expected %0d",
                         c, col_acc[c], golden_acc[c]);
                mismatches++;
            end
        end

        if (mismatches == 0)
            $display("PASS  [%s]  act=%0d  nnz_rows=%0d",
                     test_name, $signed(act), $countones(en));
        else
            $display("FAIL  [%s]  %0d column mismatches", test_name, mismatches);

        repeat(3) @(posedge clk);
    endtask

    // ─── Main test ────────────────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_cim_array.vcd");
        $dumpvars(0, tb_cim_array);

        // Reset
        rst       = 1'b1;
        acc_clear = 1'b0;
        input_act = '0;
        row_en    = '0;
        repeat(4) @(posedge clk);
        rst = 1'b0;
        repeat(2) @(posedge clk);

        $display("=================================================");
        $display("  CIM Array Testbench  N_ROWS=%0d N_COLS=%0d", N_ROWS, N_COLS);
        $display("=================================================");

        // ── Load weights — fixed pattern for reproducibility ───────────────
        // Alternating positive and negative values to exercise sign handling
        for (int i = 0; i < N_ROWS; i++) begin
            if (i % 4 == 0)      test_weights[i] =  8'sd15;
            else if (i % 4 == 1) test_weights[i] = -8'sd7;
            else if (i % 4 == 2) test_weights[i] =  8'sd31;
            else                 test_weights[i] = -8'sd3;
        end
        dut.load_weights(test_weights);
        repeat(2) @(posedge clk);

        // ── Test 1: Dense — all rows active, positive activation ───────────
        run_test("dense_all_rows_act_pos10", 8'sd10, {N_ROWS{1'b1}});

        // ── Test 2: Dense — negative activation ───────────────────────────
        run_test("dense_all_rows_act_neg8", -8'sd8, {N_ROWS{1'b1}});

        // ── Test 3: 50% sparsity — even rows only ─────────────────────────
        begin
            logic [N_ROWS-1:0] en_50;
            en_50 = '0;
            for (int i = 0; i < N_ROWS; i += 2)
                en_50[i] = 1'b1;
            run_test("50pct_sparse_even_rows", 8'sd25, en_50);
        end

        // ── Test 4: 90% sparsity — 13 rows ───────────────────────────────
        begin
            logic [N_ROWS-1:0] en_90;
            int sparse_rows [13] = '{2,11,19,34,47,58,63,71,88,99,107,115,126};
            en_90 = '0;
            for (int i = 0; i < 13; i++)
                en_90[sparse_rows[i]] = 1'b1;
            run_test("90pct_sparse_13rows", 8'sd5, en_90);
        end

        // ── Test 5: Zero activation — all col_acc must stay zero ──────────
        begin
            acc_clear = 1'b1;
            @(posedge clk); #1;
            acc_clear = 1'b0;
            input_act = 8'sd0;
            row_en    = {N_ROWS{1'b1}};
            @(posedge clk); #1;
            row_en = '0;
            @(posedge clk); #1;

            begin
                int zero_fail = 0;
                for (int c = 0; c < N_COLS; c++)
                    if (col_acc[c] !== 32'sd0) zero_fail++;
                if (zero_fail == 0)
                    $display("PASS  [zero_activation_all_acc_zero]");
                else
                    $display("FAIL  [zero_activation_all_acc_zero]  %0d cols non-zero",
                             zero_fail);
            end
        end

        // ── Test 6: Max positive operands ─────────────────────────────────
        begin
            logic [N_ROWS-1:0] en_single;
            en_single = '0;
            en_single[0] = 1'b1;    // only row 0

            // Load row 0 with max positive weight
            test_weights[0] = 8'sd127;
            dut.load_weights(test_weights);

            run_test("max_pos_w127_act127", 8'sd127, en_single);
        end

        // ── Test 7: Max negative operands ─────────────────────────────────
        begin
            logic [N_ROWS-1:0] en_single;
            en_single = '0;
            en_single[0] = 1'b1;

            test_weights[0] = -8'sd128;
            dut.load_weights(test_weights);

            run_test("max_neg_wm128_actm128", -8'sd128, en_single);
        end

        // ── Test 8: acc_clear mid-accumulation ────────────────────────────
        begin
            logic [N_ROWS-1:0] en_half;
            en_half = '0;
            for (int i = 0; i < N_ROWS/2; i++) en_half[i] = 1'b1;

            // Load known weights
            for (int i = 0; i < N_ROWS; i++) test_weights[i] = 8'sd10;
            dut.load_weights(test_weights);

            // Accumulate first half
            acc_clear = 1'b0;
            input_act = 8'sd3;
            row_en    = en_half;
            @(posedge clk); #1;
            row_en = '0;
            @(posedge clk); #1;

            // Clear mid-way
            acc_clear = 1'b1;
            @(posedge clk); #1;
            acc_clear = 1'b0;
            @(posedge clk); #1;

            begin
                int clear_fail = 0;
                for (int c = 0; c < N_COLS; c++)
                    if (col_acc[c] !== 32'sd0) clear_fail++;
                if (clear_fail == 0)
                    $display("PASS  [acc_clear_mid_accumulation]");
                else
                    $display("FAIL  [acc_clear_mid_accumulation]  %0d cols non-zero",
                             clear_fail);
            end
        end

        // ── Test 9: Accumulation across multiple activations ──────────────
        // Real inference: multiple activations accumulate before reading out
        begin
            logic [N_ROWS-1:0] en_all;
            logic signed [31:0] running_golden [0:N_COLS-1];
            int multi_fail;

            for (int c = 0; c < N_COLS; c++) running_golden[c] = '0;

            for (int i = 0; i < N_ROWS; i++) test_weights[i] = 8'sd4;
            dut.load_weights(test_weights);
            en_all = {N_ROWS{1'b1}};

            // Clear first
            acc_clear = 1'b1;
            @(posedge clk); #1;
            acc_clear = 1'b0;

            // Three separate activation values accumulate into same array
            foreach ('{8'sd3, 8'sd7, -8'sd2}[act_idx]) begin
                automatic logic signed [7:0] cur_act;
                cur_act   = '{8'sd3, 8'sd7, -8'sd2}[act_idx];
                input_act = cur_act;
                row_en    = en_all;
                @(posedge clk); #1;
                row_en = '0;
                @(posedge clk); #1;

                // Update running golden
                for (int rr = 0; rr < N_ROWS; rr++) begin
                    automatic logic signed [15:0] p;
                    p = approx_mult_model(test_weights[rr], cur_act);
                    running_golden[rr % N_COLS] += {{16{p[15]}}, p};
                end
            end

            // Compare
            multi_fail = 0;
            for (int c = 0; c < N_COLS; c++)
                if (col_acc[c] !== running_golden[c]) multi_fail++;

            if (multi_fail == 0)
                $display("PASS  [multi_activation_accumulation_3_steps]");
            else
                $display("FAIL  [multi_activation_accumulation_3_steps]  %0d mismatches",
                         multi_fail);
        end

        $display("=================================================");
        $display("  All CIM array tests complete.");
        $display("=================================================");
        $finish;
    end

    // ─── Timeout watchdog ─────────────────────────────────────────────────────
    initial begin
        #1000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule