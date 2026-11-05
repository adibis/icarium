// CDC-024: one source bit fans out to two independent 2FF chains
// in the same foreign domain. The chains never recombine, so
// CDC-005 stays silent; the fanout itself still needs the
// independence judgement.
module bad_fanout (
    input  wire clk_a,
    input  wire clk_b,
    input  wire flag_in,
    output wire flag_a,
    output wire flag_b
);
    reg flag_q;
    always_ff @(posedge clk_a) flag_q <= flag_in;

    reg a1, a2;
    always_ff @(posedge clk_b) a1 <= flag_q;
    always_ff @(posedge clk_b) a2 <= a1;

    reg b1, b2;
    always_ff @(posedge clk_b) b1 <= flag_q;
    always_ff @(posedge clk_b) b2 <= b1;

    assign flag_a = a2;
    assign flag_b = b2;
endmodule
