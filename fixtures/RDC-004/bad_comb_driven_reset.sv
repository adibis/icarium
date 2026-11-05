// RDC-004: a comb AND of two flop outputs drives an ARST pin.
// The gate glitches on near-simultaneous input changes, and
// each transient reads as a reset assertion. Single clock, so
// only the comb-on-reset rule fires.
module bad_comb_driven_reset (
    input  logic clk,
    input  logic global_rst_n,
    input  logic kill_a,
    input  logic kill_b,
    input  logic d_in,
    output logic q_out
);

    logic flop_a, flop_b;
    always_ff @(posedge clk or negedge global_rst_n) begin
        if (!global_rst_n) begin
            flop_a <= 1'b0;
            flop_b <= 1'b0;
        end else begin
            flop_a <= ~kill_a;
            flop_b <= ~kill_b;
        end
    end

    logic comb_rst;
    assign comb_rst = flop_a & flop_b;

    always_ff @(posedge clk or negedge comb_rst) begin
        if (!comb_rst) q_out <= 1'b0;
        else           q_out <= d_in;
    end

endmodule
