// CDC-025: fully typed single-clock path. Every endpoint has a
// clock association and the pairs are synchronous: silent.
module good_typed_pair (
    input  wire clk,
    input  wire d,
    output wire q
);
    reg a_r;
    reg b_r;
    always_ff @(posedge clk) a_r <= d;
    always_ff @(posedge clk) b_r <= a_r;
    assign q = b_r;
endmodule
