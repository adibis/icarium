// RDC-007 clean: the chain head loads the deasserted value,
// so the tail releases one cycle per stage after the port
// releases, and the consumer leaves reset as intended.
module good_chain_deassert_polarity (
    input  logic dst_clk,
    input  logic raw_rst_n,
    input  logic d_in,
    output logic q_out
);

    logic meta, rst_n_sync;
    always_ff @(posedge dst_clk or negedge raw_rst_n) begin
        if (!raw_rst_n) begin
            meta       <= 1'b0;
            rst_n_sync <= 1'b0;
        end else begin
            meta       <= 1'b1;
            rst_n_sync <= meta;
        end
    end

    always_ff @(posedge dst_clk or negedge rst_n_sync) begin
        if (!rst_n_sync) q_out <= 1'b0;
        else             q_out <= d_in;
    end

endmodule
