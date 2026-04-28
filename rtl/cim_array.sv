// =============================================================================
// Module      : cim_array
// Project     : EcoMAC Neural Accelerator
// Description : 128x8 digital Compute-in-Memory array.
//               Each row stores one INT8 weight and contains one instance
//               of approx_multiplier. When row_en[i] is asserted by the
//               sparse controller, the broadcast input activation is
//               multiplied in-place by the stored weight. Products accumulate
//               in per-column 32-bit accumulators. Weights never leave the
//               array boundary — no external datapath switching.
//
// Parameters  :
//   N_ROWS      — number of weight rows (128 for 128->10 layer)
//   N_COLS      — number of output neurons / column accumulators (10)
//   DATA_WIDTH  — operand bit width (8 for INT8)
//   APPROX_BITS — passed through to approx_multiplier (default 4)
//
// Interface   :
//   clk         — 50 MHz system clock
//   rst         — synchronous active-high reset
//   input_act   — broadcast INT8 activation (held stable during dispatch)
//   row_en      — per-row enable from sparse_controller
//   acc_clear   — clears all column accumulators (pulse before new inference)
//   col_acc     — 32-bit accumulated partial sums per output neuron
//   acc_valid   — high when accumulation is in progress
//
// Row-to-column mapping:
//   Row r contributes to column (r % N_COLS)
//   For N_ROWS=128, N_COLS=10: rows 0,10,20...->col0; rows 1,11,21...->col1 etc.
// =============================================================================

module cim_array #(
    parameter int N_ROWS      = 128,
    parameter int N_COLS      = 10,
    parameter int DATA_WIDTH  = 8,
    parameter int APPROX_BITS = 4
)(
    input  logic                          clk,
    input  logic                          rst,
    input  logic signed [DATA_WIDTH-1:0]  input_act,
    input  logic [N_ROWS-1:0]             row_en,
    input  logic                          acc_clear,
    output logic signed [31:0]            col_acc [0:N_COLS-1],
    output logic                          acc_valid
);

    // ─── Local parameters ─────────────────────────────────────────────────────
    localparam int PRODUCT_WIDTH = 2 * DATA_WIDTH;  // 16-bit products

    // ─── Weight storage ───────────────────────────────────────────────────────
    // In the full design these are loaded from BRAM via hex files.
    // Here declared as registers — top_module initialises them at startup.
    logic signed [DATA_WIDTH-1:0] weight_mem [0:N_ROWS-1];

    // ─── Per-row multiplier outputs ───────────────────────────────────────────
    logic signed [PRODUCT_WIDTH-1:0] row_product [0:N_ROWS-1];
    logic signed [PRODUCT_WIDTH-1:0] row_product_gated [0:N_ROWS-1];

    // ─── Instantiate one approx_multiplier per row ────────────────────────────
    genvar r;
    generate
        for (r = 0; r < N_ROWS; r++) begin : gen_rows
            approx_multiplier #(
                .DATA_WIDTH  (DATA_WIDTH),
                .APPROX_BITS (APPROX_BITS)
            ) mult_inst (
                .operand_a (weight_mem[r]),
                .operand_b (input_act),
                .result    (row_product[r])
            );

            // Gate the product: if row not enabled, force to zero
            // This is the key CIM power saving — no switching on disabled rows
            assign row_product_gated[r] = row_en[r] ? row_product[r]
                                                     : '0;
        end
    endgenerate

    // ─── Column accumulators ──────────────────────────────────────────────────
    // Accumulate enabled row products into their mapped output column
    // Row r maps to column (r % N_COLS)

    always_ff @(posedge clk) begin
        if (rst || acc_clear) begin
            for (int c = 0; c < N_COLS; c++)
                col_acc[c] <= '0;
            acc_valid <= 1'b0;
        end
        else begin
            acc_valid <= |row_en;   // valid while any row is being processed

            // Each enabled row adds its product to the correct column
            for (int rr = 0; rr < N_ROWS; rr++) begin
                if (row_en[rr])
                    col_acc[rr % N_COLS] <= col_acc[rr % N_COLS]
                                          + {{(32-PRODUCT_WIDTH){row_product_gated[rr][PRODUCT_WIDTH-1]}},
                                             row_product_gated[rr]};
            end
        end
    end

    // ─── Weight loading interface ─────────────────────────────────────────────
    // Public task — called by top_module or testbench to initialise weights
    // In synthesis this maps to BRAM initialisation via $readmemh
    task automatic load_weights(input logic signed [DATA_WIDTH-1:0] w [0:N_ROWS-1]);
        for (int i = 0; i < N_ROWS; i++)
            weight_mem[i] = w[i];
    endtask

    // ─── Assertions ───────────────────────────────────────────────────────────
    // pragma translate_off
    always_ff @(posedge clk) begin
        // Overflow detection on column accumulators
        for (int c = 0; c < N_COLS; c++) begin
            assert (col_acc[c] < 32'sh7FFFFFFF)
                else $warning("cim_array: col_acc[%0d] approaching overflow: %0d",
                              c, col_acc[c]);
        end
    end
    // pragma translate_on

endmodule