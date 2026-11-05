// CDC-017: a latch posed as a first sync stage. While the
// enable holds, the src-domain value flows transparently to
// the dst flop's D pin with no resolution time at all.
module bad_latch_stage (
    input  logic src_clk,
    input  logic dst_clk,
    input  logic latch_en,
    input  logic d_in,
    output logic q_out
);

    logic src_q;
    always_ff @(posedge src_clk) src_q <= d_in;

    logic latch_q;
    always_latch
        if (latch_en) latch_q = src_q;

    logic sync_q;
    always_ff @(posedge dst_clk) sync_q <= latch_q;

    assign q_out = sync_q;

endmodule
