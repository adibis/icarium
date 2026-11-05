// RDC-007: an active-low reset chain whose head loads 1'b0,
// the asserted value, instead of 1'b1. Structurally a fine
// chain otherwise, so recognition accepts it; the tail then
// holds downstream consumers in reset forever.
module bad_chain_deassert_polarity (
    input  logic dst_clk,
    input  logic raw_rst_n,
    output logic rst_n_sync
);

    logic meta;
    always_ff @(posedge dst_clk or negedge raw_rst_n) begin
        if (!raw_rst_n) meta <= 1'b0;
        else            meta <= 1'b0;
    end
    always_ff @(posedge dst_clk or negedge raw_rst_n) begin
        if (!raw_rst_n) rst_n_sync <= 1'b0;
        else            rst_n_sync <= meta;
    end

endmodule
