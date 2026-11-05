// CDC-023: one clock gated by a data enable, feeding a 2FF.
// A single clock leg plus an enable resolves; only genuine
// two-clock combines decline. Nothing fires.
module good_gated_clock (
    input  logic clk,
    input  logic en,
    input  logic d,
    output logic q
);

    wire gclk = clk & en;

    logic src_q, s1, s2;
    always_ff @(posedge clk) src_q <= d;
    always_ff @(posedge gclk) begin
        s1 <= src_q;
        s2 <= s1;
    end

    assign q = s2;

endmodule
