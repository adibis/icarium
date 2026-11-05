// RDC-011: one reset net drives an async pin (a_q), a sync
// pin (s_q), and both at once (c_q, whose D-mux keys on the
// same net). The groups can never leave reset together.
module bad_dual_use (
    input  wire clk,
    input  wire rst,
    input  wire d,
    output wire q
);
    reg a_q;
    always_ff @(posedge clk or posedge rst)
        if (rst) a_q <= 1'b0;
        else     a_q <= d;

    reg s_q;
    always_ff @(posedge clk)
        if (rst) s_q <= 1'b0;
        else     s_q <= a_q;

    reg c_q;
    always_ff @(posedge clk or posedge rst)
        if (rst) c_q <= 1'b0;
        else     c_q <= rst ? 1'b1 : d;

    assign q = s_q & c_q;
endmodule
