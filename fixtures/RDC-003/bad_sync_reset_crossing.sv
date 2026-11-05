// RDC-003: a src-domain flop drives the sync reset of a dst
// flop directly (mux-on-D spelling on the no-opt flow). The
// destination samples its reset on its own edge from a foreign
// source, which is the SRST analogue of an ARST crossing.
// CDC-001 fires beside it: the mux select reaches D through the
// gate, so the data path sees the same foreign source. RDC-009
// stays silent by design: the destination's own async reset puts
// both sides in reset domains, but the foreign flop arrives only
// through the mux select, which is control rather than data.
module bad_sync_reset_crossing (
    input  logic src_clk,
    input  logic dst_clk,
    input  logic global_rst_n,
    input  logic dst_rst_n,
    input  logic kill_req,
    input  logic d_in,
    output logic q_out
);

    logic src_rst;
    always_ff @(posedge src_clk or negedge global_rst_n) begin
        if (!global_rst_n) src_rst <= 1'b0;
        else               src_rst <= kill_req;
    end

    logic q_dst;
    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) q_dst <= 1'b0;
        else if (src_rst) q_dst <= 1'b0;
        else         q_dst <= d_in;
    end

    assign q_out = q_dst;

endmodule
