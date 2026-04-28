// =============================================================================
// Testbench   : tb_approx_multiplier
// Description : Exhaustive 8-bit test — all 65,536 input combinations.
//               Computes MRED vs exact multiplier.
//               Sweeps APPROX_BITS 2, 4, 6 and reports tradeoff table.
//               Checks sign correctness across all quadrants.
// =============================================================================

`timescale 1ns/1ps

module tb_approx_multiplier;

    // ─── Parameters ───────────────────────────────────────────────────────────
    localparam int DATA_WIDTH   = 8;
    localparam int PRODUCT_WIDTH = 16;

    // ─── DUT signals — one instance per APPROX_BITS setting ──────────────────
    logic signed [DATA_WIDTH-1:0]    op_a, op_b;

    logic signed [PRODUCT_WIDTH-1:0] result_ab2;   // APPROX_BITS = 2
    logic signed [PRODUCT_WIDTH-1:0] result_ab4;   // APPROX_BITS = 4
    logic signed [PRODUCT_WIDTH-1:0] result_ab6;   // APPROX_BITS = 6
    logic signed [PRODUCT_WIDTH-1:0] result_exact; // exact reference

    // ─── DUT instantiations ───────────────────────────────────────────────────
    approx_multiplier #(.DATA_WIDTH(8), .APPROX_BITS(2)) dut_ab2 (
        .operand_a(op_a), .operand_b(op_b), .result(result_ab2));

    approx_multiplier #(.DATA_WIDTH(8), .APPROX_BITS(4)) dut_ab4 (
        .operand_a(op_a), .operand_b(op_b), .result(result_ab4));

    approx_multiplier #(.DATA_WIDTH(8), .APPROX_BITS(6)) dut_ab6 (
        .operand_a(op_a), .operand_b(op_b), .result(result_ab6));

    // Exact reference: APPROX_BITS=0 equivalent — use SystemVerilog multiply
    // directly for ground truth rather than another module instance
    assign result_exact = op_a * op_b;

    // ─── MRED accumulators ────────────────────────────────────────────────────
    real mred_ab2, mred_ab4, mred_ab6;
    real total_rel_err_ab2, total_rel_err_ab4, total_rel_err_ab6;
    real abs_err, rel_err;
    int  total_cases;
    int  nonzero_cases;           // skip (0,x) and (x,0) for relative error
    int  sign_errors;             // track sign mismatches separately

    // ─── Waveform dump ────────────────────────────────────────────────────────
    initial begin
        $dumpfile("tb_approx_multiplier.vcd");
        $dumpvars(0, tb_approx_multiplier);
    end

    // ─── Main test ────────────────────────────────────────────────────────────
    initial begin
        total_rel_err_ab2 = 0.0;
        total_rel_err_ab4 = 0.0;
        total_rel_err_ab6 = 0.0;
        total_cases  = 0;
        nonzero_cases = 0;
        sign_errors  = 0;

        $display("=================================================");
        $display("  Approximate Multiplier — Exhaustive Test");
        $display("  DATA_WIDTH=%0d | Testing APPROX_BITS = 2, 4, 6", DATA_WIDTH);
        $display("=================================================");

        // ── Sweep all 256 x 256 signed input combinations ─────────────────
        for (int a = -128; a <= 127; a++) begin
            for (int b = -128; b <= 127; b++) begin

                op_a = a[DATA_WIDTH-1:0];
                op_b = b[DATA_WIDTH-1:0];
                #5; // combinational settle time

                total_cases++;

                // Sign check: exact and approx must agree on sign
                // (skip zero products — sign undefined)
                if ((a * b) != 0) begin
                    if (result_exact[PRODUCT_WIDTH-1] !== result_ab4[PRODUCT_WIDTH-1])
                        sign_errors++;
                end

                // Relative error — skip when exact product is zero
                // (division by zero meaningless; approx must also be zero)
                if ((a * b) != 0) begin
                    nonzero_cases++;

                    // APPROX_BITS = 2
                    abs_err = $abs($signed(result_ab2) - $signed(result_exact));
                    total_rel_err_ab2 += abs_err / $abs($signed(result_exact));

                    // APPROX_BITS = 4
                    abs_err = $abs($signed(result_ab4) - $signed(result_exact));
                    total_rel_err_ab4 += abs_err / $abs($signed(result_exact));

                    // APPROX_BITS = 6
                    abs_err = $abs($signed(result_ab6) - $signed(result_exact));
                    total_rel_err_ab6 += abs_err / $abs($signed(result_exact));
                end

                // Spot-check: when both operands are zero, result must be zero
                if (a == 0 || b == 0) begin
                    assert (result_ab4 === '0)
                        else $error("Zero-operand failure: a=%0d b=%0d result=%0d",
                                    a, b, result_ab4);
                end
            end
        end

        // ── Compute MRED ───────────────────────────────────────────────────
        mred_ab2 = (total_rel_err_ab2 / nonzero_cases) * 100.0;
        mred_ab4 = (total_rel_err_ab4 / nonzero_cases) * 100.0;
        mred_ab6 = (total_rel_err_ab6 / nonzero_cases) * 100.0;

        // ── Print results table ────────────────────────────────────────────
        $display("");
        $display("  Results Summary");
        $display("  %-14s | %-10s | %-10s | %s",
                 "APPROX_BITS", "MRED (%)", "Pass/Fail", "Note");
        $display("  %s", {"─"*60});

        begin
            string pf2, pf4, pf6;
            pf2 = (mred_ab2 <= 5.0) ? "PASS" : "FAIL";
            pf4 = (mred_ab4 <= 5.0) ? "PASS" : "FAIL";
            pf6 = (mred_ab6 <= 5.0) ? "PASS" : "FAIL";
            $display("  %-14d | %-10.4f | %-10s | Light approximation",
                     2, mred_ab2, pf2);
            $display("  %-14d | %-10.4f | %-10s | Recommended default",
                     4, mred_ab4, pf4);
            $display("  %-14d | %-10.4f | %-10s | Aggressive",
                     6, mred_ab6, pf6);
        end

        $display("  %s", {"─"*60});
        $display("  Total input pairs tested : %0d", total_cases);
        $display("  Non-zero pairs (for MRED): %0d", nonzero_cases);
        $display("  Sign errors (APPROX_BITS=4): %0d", sign_errors);

        // ── Specific value checks ──────────────────────────────────────────
        $display("");
        $display("  Spot Checks (APPROX_BITS=4)");
        $display("  %-8s %-8s %-10s %-10s %-8s",
                 "op_a", "op_b", "Exact", "Approx", "Error");

        begin
            logic signed [DATA_WIDTH-1:0]    ta, tb;
            logic signed [PRODUCT_WIDTH-1:0] te, tapprox;
            int check_a [8] = '{10, -10, 127, -128, 50, -50, 1, -1};
            int check_b [8] = '{10, -10, 127, -128, -50, 50, 127, -128};

            for (int c = 0; c < 8; c++) begin
                op_a = check_a[c][DATA_WIDTH-1:0];
                op_b = check_b[c][DATA_WIDTH-1:0];
                #5;
                te      = op_a * op_b;
                tapprox = result_ab4;
                $display("  %-8d %-8d %-10d %-10d %-8d",
                         $signed(op_a), $signed(op_b),
                         $signed(te), $signed(tapprox),
                         $signed(tapprox) - $signed(te));
            end
        end

        // ── Final verdict ──────────────────────────────────────────────────
        $display("");
        if (mred_ab4 <= 5.0 && sign_errors == 0)
            $display("  OVERALL: PASS — APPROX_BITS=4 meets MRED<=5%% target");
        else begin
            $display("  OVERALL: FAIL");
            if (mred_ab4 > 5.0)
                $display("  REASON : MRED=%.4f%% exceeds 5%% threshold", mred_ab4);
            if (sign_errors > 0)
                $display("  REASON : %0d sign errors detected", sign_errors);
        end

        $display("=================================================");
        $finish;
    end

endmodule