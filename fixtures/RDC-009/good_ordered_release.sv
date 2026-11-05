// RDC-009: destination reset derives from the source's own root
// through a synchronizer chain, so the destination wakes strictly
// after the source data settles. Ordered release, silent.
// RDC-010 still notes the chain and warns on the source's raw
// root: the mix is ordered here, but uniformity gets a review.
module good_ordered_release (
    input  wire clk,
    input  wire rst,
    input  wire d,
    output wire q
);
    reg src_q;
    always_ff @(posedge clk or posedge rst)
        if (rst) src_q <= 1'b0;
        else     src_q <= d;

    reg s1_q, s2_q;
    always_ff @(posedge clk or posedge rst)
        if (rst) s1_q <= 1'b1;
        else     s1_q <= 1'b0;
    always_ff @(posedge clk or posedge rst)
        if (rst) s2_q <= 1'b1;
        else     s2_q <= s1_q;

    reg dst_q;
    always_ff @(posedge clk or posedge s2_q)
        if (s2_q) dst_q <= 1'b0;
        else      dst_q <= src_q;

    assign q = dst_q;
endmodule
