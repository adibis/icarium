// CDC-018: a 4-deep chain, at the default threshold. Safe, but two
// stacked 2FF syncs cost latency and often mark a doubled fix or a
// leftover wrapper. Depth checks pass; only the policy rule fires.
module bad_deep_chain (
    input  logic src_clk,
    input  logic dst_clk,
    input  logic d_in,
    output logic q_out
);

    logic src_q;
    always_ff @(posedge src_clk) src_q <= d_in;

    logic meta, sync_q, sync2_meta, sync2_q;
    always_ff @(posedge dst_clk) begin
        meta       <= src_q;
        sync_q     <= meta;
        sync2_meta <= sync_q;
        sync2_q    <= sync2_meta;
    end

    assign q_out = sync2_q;

endmodule
