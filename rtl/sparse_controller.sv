// =============================================================================
// Module      : sparse_controller
// Project     : EcoMAC Neural Accelerator
// Description : Reads CSR-format weight index array from BRAM and generates
//               per-row enable signals for the CIM array. Zero-weight rows
//               are never enabled — no memory read, no switching activity.
//
// Parameters  :
//   N_ROWS      — number of rows in the CIM array (must match cim_array.sv)
//   IDX_WIDTH   — bit width of each index value (log2 of N_ROWS)
//   MAX_NNZ     — maximum number of non-zero weights (worst case = N_ROWS)
//
// Interface   :
//   clk         — system clock (50 MHz)
//   rst         — synchronous active-high reset
//   start       — pulse high for 1 cycle to begin a new dispatch sequence
//   nnz_count   — number of non-zero entries in the CSR index array
//                 (set by top module before asserting start)
//   idx_addr    — read address driven into the CSR index BRAM
//   idx_data    — data returned from BRAM (registered, 1-cycle latency)
//   row_en      — one-hot/multi-hot enable to CIM array rows
//   valid       — high while row_en is being actively updated (dispatch phase)
//   done        — pulses high for 1 cycle when all indices dispatched
// =============================================================================

module sparse_controller #(
    parameter int N_ROWS    = 128,
    parameter int IDX_WIDTH = 7,        // log2(128) = 7
    parameter int MAX_NNZ   = 128       // worst case: all weights non-zero
)(
    input  logic                  clk,
    input  logic                  rst,
    input  logic                  start,
    input  logic [$clog2(MAX_NNZ)-1:0] nnz_count,  // how many non-zero weights

    // CSR index BRAM interface
    output logic [$clog2(MAX_NNZ)-1:0] idx_addr,
    input  logic [IDX_WIDTH-1:0]       idx_data,

    // CIM array interface
    output logic [N_ROWS-1:0]     row_en,
    output logic                  valid,
    output logic                  done
);

    // ─── FSM state encoding ───────────────────────────────────────────────────
    typedef enum logic [1:0] {
        IDLE     = 2'b00,
        LOAD     = 2'b01,
        DISPATCH = 2'b10,
        DONE_ST  = 2'b11
    } state_t;

    state_t current_state, next_state;

    // ─── Internal registers ───────────────────────────────────────────────────
    logic [$clog2(MAX_NNZ)-1:0] addr_counter;   // tracks which index we're reading
    logic [$clog2(MAX_NNZ)-1:0] nnz_latch;      // latched copy of nnz_count at start
    logic [IDX_WIDTH-1:0]       captured_idx;   // index captured after BRAM latency

    // ─── State register (sequential) ─────────────────────────────────────────
    always_ff @(posedge clk) begin
        if (rst)
            current_state <= IDLE;
        else
            current_state <= next_state;
    end

    // ─── Next-state logic (combinational) ────────────────────────────────────
    always_comb begin
        next_state = current_state;     // default: stay in current state

        case (current_state)
            IDLE: begin
                if (start)
                    next_state = LOAD;
            end

            LOAD: begin
                // One cycle to present address, next cycle BRAM data is valid
                // Transition immediately — BRAM data captured in DISPATCH
                next_state = DISPATCH;
            end

            DISPATCH: begin
                if (addr_counter >= nnz_latch - 1)
                    next_state = DONE_ST;
                else
                    next_state = LOAD;
            end

            DONE_ST: begin
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    // ─── Datapath (sequential) ────────────────────────────────────────────────
    always_ff @(posedge clk) begin
        if (rst) begin
            addr_counter  <= '0;
            nnz_latch     <= '0;
            captured_idx  <= '0;
            row_en        <= '0;
            valid         <= 1'b0;
            done          <= 1'b0;
            idx_addr      <= '0;
        end
        else begin
            // Default: deassert single-cycle signals
            done  <= 1'b0;
            valid <= 1'b0;

            case (current_state)

                IDLE: begin
                    row_en       <= '0;         // clear row enables for new inference
                    addr_counter <= '0;
                    idx_addr     <= '0;
                    if (start)
                        nnz_latch <= nnz_count; // latch nnz before start pulse gone
                end

                LOAD: begin
                    // Drive BRAM address — data appears next cycle
                    idx_addr <= addr_counter;
                    valid    <= 1'b1;
                end

                DISPATCH: begin
                    // BRAM data is now valid — capture and set the corresponding row
                    captured_idx             <= idx_data;
                    row_en[idx_data]         <= 1'b1;   // enable this CIM row
                    addr_counter             <= addr_counter + 1;
                    valid                    <= 1'b1;
                end

                DONE_ST: begin
                    done  <= 1'b1;
                    valid <= 1'b0;
                end

            endcase
        end
    end

    // ─── Assertions (synthesisable subset — caught in simulation) ────────────
    // Verify idx_data never points outside the valid row range
    // pragma translate_off
    always_ff @(posedge clk) begin
        if (current_state == DISPATCH) begin
            assert (idx_data < N_ROWS)
                else $error("sparse_controller: idx_data %0d out of range (N_ROWS=%0d)",
                            idx_data, N_ROWS);
        end
    end
    // pragma translate_on

endmodule