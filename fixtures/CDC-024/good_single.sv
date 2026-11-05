// CDC-024: one source into one 2FF chain. No fanout, no finding.
module good_single (
    input  wire clk_a,
    input  wire clk_b,
    input  wire flag_in,
    output wire flag_out
);
    reg flag_q;
    always_ff @(posedge clk_a) flag_q <= flag_in;

    reg a1, a2;
    always_ff @(posedge clk_b) a1 <= flag_q;
    always_ff @(posedge clk_b) a2 <= a1;

    assign flag_out = a2;
endmodule
