// RDC-011: one reset net is the async reset of a_q and the sync
// reset of s_q. Each drives its own output, so synthesis keeps both
// uses. The two groups can never leave reset together.
module bad_dual_use (
    input  wire clk,
    input  wire rst,
    input  wire d,
    output wire qa,
    output wire qs
);
    reg a_q;
    always_ff @(posedge clk or posedge rst)
        if (rst) a_q <= 1'b0;
        else     a_q <= d;

    reg s_q;
    always_ff @(posedge clk)
        if (rst) s_q <= 1'b0;
        else     s_q <= d;

    assign qa = a_q;
    assign qs = s_q;
endmodule
