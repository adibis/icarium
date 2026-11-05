// CDC-017: the same latch shape, but source and destination
// share one clock. Transparency is harmless in-domain.
module good_same_domain_latch (
    input  logic clk,
    input  logic latch_en,
    input  logic d_in,
    output logic q_out
);

    logic src_q;
    always_ff @(posedge clk) src_q <= d_in;

    logic latch_q;
    always_latch
        if (latch_en) latch_q = src_q;

    logic sync_q;
    always_ff @(posedge clk) sync_q <= latch_q;

    assign q_out = sync_q;

endmodule
