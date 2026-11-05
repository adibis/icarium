// RDC-002: single clock, no CDC crossing at all. The producer
// flop wakes from reset driving 0, but the consumer's ARST pin
// asserts on 1: the consumer never enters reset with the system.
module bad_flop_mismatch (
    input  logic clk,
    input  logic raw_rst_n,
    output logic q_out
);

    logic gated_rst;
    always_ff @(posedge clk or negedge raw_rst_n) begin
        if (!raw_rst_n) gated_rst <= 1'b0;
        else            gated_rst <= 1'b1;
    end

    always_ff @(posedge clk or posedge gated_rst) begin
        if (gated_rst) q_out <= 1'b0;
        else           q_out <= 1'b1;
    end

endmodule
