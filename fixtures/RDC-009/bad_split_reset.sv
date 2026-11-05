// RDC-009: source and destination flops sit on different async
// resets under one clock. Same clock, different release order:
// the source can come out of reset while the receiver samples.
module bad_split_reset (
    input  wire clk,
    input  wire rst_a,
    input  wire rst_b,
    input  wire d,
    output wire q
);
    reg src_q;
    always_ff @(posedge clk or posedge rst_a)
        if (rst_a) src_q <= 1'b0;
        else       src_q <= d;

    reg dst_q;
    always_ff @(posedge clk or posedge rst_b)
        if (rst_b) dst_q <= 1'b0;
        else       dst_q <= src_q;

    assign q = dst_q;
endmodule
