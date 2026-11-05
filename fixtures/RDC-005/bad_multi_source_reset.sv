// RDC-005: two independent board resets ANDed onto one ARST
// pin with no flop behind the gate. The sources release at
// independent times, so the release edge is undefined. RDC-004
// skips port-only comb, which is why this rule exists.
module bad_multi_source_reset (
    input  logic clk,
    input  logic global_rst_n,
    input  logic block_rst_n,
    input  logic d_in,
    output logic q_out
);

    logic combined_rst_n;
    assign combined_rst_n = global_rst_n & block_rst_n;

    always_ff @(posedge clk or negedge combined_rst_n) begin
        if (!combined_rst_n) q_out <= 1'b0;
        else                 q_out <= d_in;
    end

endmodule
