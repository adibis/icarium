// CDC-018: the textbook 2FF chain. Below the threshold,
// so nothing fires.
module good_two_deep (
    input  logic src_clk,
    input  logic dst_clk,
    input  logic d_in,
    output logic q_out
);

    logic src_q;
    always_ff @(posedge src_clk) src_q <= d_in;

    logic meta, sync_q;
    always_ff @(posedge dst_clk) begin
        meta   <= src_q;
        sync_q <= meta;
    end

    assign q_out = sync_q;

endmodule
