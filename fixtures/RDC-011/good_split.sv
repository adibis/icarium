// RDC-011: async and sync resets arrive on separate nets,
// so no root serves both contracts. The rule stays silent.
module good_split (
    input  wire clk,
    input  wire rst_a,
    input  wire rst_s,
    input  wire d,
    output wire q
);
    reg a_q;
    always_ff @(posedge clk or posedge rst_a)
        if (rst_a) a_q <= 1'b0;
        else       a_q <= d;

    reg s_q;
    always_ff @(posedge clk)
        if (rst_s) s_q <= 1'b0;
        else       s_q <= a_q;

    assign q = s_q;
endmodule
