// RDC-009: both flops share one async reset. Same release, silent.
module good_shared_reset (
    input  wire clk,
    input  wire rst,
    input  wire d,
    output wire q
);
    reg src_q;
    always_ff @(posedge clk or posedge rst)
        if (rst) src_q <= 1'b0;
        else     src_q <= d;

    reg dst_q;
    always_ff @(posedge clk or posedge rst)
        if (rst) dst_q <= 1'b0;
        else     dst_q <= src_q;

    assign q = dst_q;
endmodule
