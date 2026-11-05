// Pragma case: two unsynchronized crossings, but only the
// first sits inside the disable region; the second stands.
// icarium: disable-rule CDC-001 first crossing vetted
module pragma_scoped (
    input  logic clk_a,
    input  logic clk_b,
    input  logic d1,
    input  logic d2,
    output logic q1,
    output logic q2
);

    logic a1;
    always_ff @(posedge clk_a) a1 <= d1;
    always_ff @(posedge clk_b) q1 <= a1;
    // icarium: enable-rule CDC-001

    logic a2;
    always_ff @(posedge clk_a) a2 <= d2;
    always_ff @(posedge clk_b) q2 <= a2;

endmodule
