// RDC-002: the producer has no reset of its own, so it holds
// no reset value to disagree with the consumer's sense. The
// rule skips resetless producers; direct flop drive without
// comb stays silent across the reset rules in one domain.
module good_resetless_producer (
    input  logic clk,
    input  logic raw_rst,
    output logic q_out
);

    logic gated_rst;
    always_ff @(posedge clk) gated_rst <= raw_rst;

    always_ff @(posedge clk or posedge gated_rst) begin
        if (gated_rst) q_out <= 1'b0;
        else           q_out <= 1'b1;
    end

endmodule
