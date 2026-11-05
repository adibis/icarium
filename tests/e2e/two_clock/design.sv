// Deliberately unsynchronized crossing.
module two_clock (
    input  logic clk_a,
    input  logic clk_b,
    input  logic d,
    output logic q
);
    logic cross;
    always_ff @(posedge clk_a) cross <= d;
    always_ff @(posedge clk_b) q <= cross;
endmodule
