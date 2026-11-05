// RDC-006: a mux selects the reset source, but the selected
// reset drives ARST directly with no local synchronizer. The
// mux excuses RDC-005; the async deassertion still reports here.
module bad_muxed_reset_unsync (
    input  logic clk,
    input  logic global_rst_n,
    input  logic block_rst_n,
    input  logic use_block_rst,
    input  logic d_in,
    output logic q_out
);

    logic selected_rst_n;
    assign selected_rst_n = use_block_rst ? block_rst_n : global_rst_n;

    always_ff @(posedge clk or negedge selected_rst_n) begin
        if (!selected_rst_n) q_out <= 1'b0;
        else                 q_out <= d_in;
    end

endmodule
