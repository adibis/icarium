// RDC-005: the two sources mux-select into a reset-sync chain
// instead of ANDing onto the pin. Chain members exempt, and
// the consumer's reset comes from the tail flop, so the port
// count never reaches two without a flop behind it.
module good_muxed_reset (
    input  logic clk,
    input  logic global_rst_n,
    input  logic block_rst_n,
    input  logic use_block_rst,
    input  logic d_in,
    output logic q_out
);

    logic selected_rst_n;
    assign selected_rst_n = use_block_rst ? block_rst_n : global_rst_n;

    logic rst_meta_n;
    logic rst_sync_n;
    always_ff @(posedge clk or negedge selected_rst_n) begin
        if (!selected_rst_n) begin
            rst_meta_n <= 1'b0;
            rst_sync_n <= 1'b0;
        end else begin
            rst_meta_n <= 1'b1;
            rst_sync_n <= rst_meta_n;
        end
    end

    always_ff @(posedge clk or negedge rst_sync_n) begin
        if (!rst_sync_n) q_out <= 1'b0;
        else             q_out <= d_in;
    end

endmodule
