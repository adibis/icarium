// RDC-003: the foreign reset passes through a 2FF chain in
// dst_clk before touching the sync reset. Same-domain drive
// at the select, so nothing fires.
module good_sync_reset_synced (
    input  logic src_clk,
    input  logic dst_clk,
    input  logic global_rst_n,
    input  logic kill_req,
    input  logic d_in,
    output logic q_out
);

    logic src_rst;
    always_ff @(posedge src_clk or negedge global_rst_n) begin
        if (!global_rst_n) src_rst <= 1'b0;
        else               src_rst <= kill_req;
    end

    logic src_rst_meta, src_rst_sync;
    always_ff @(posedge dst_clk or negedge global_rst_n) begin
        if (!global_rst_n) begin
            src_rst_meta <= 1'b0;
            src_rst_sync <= 1'b0;
        end else begin
            src_rst_meta <= src_rst;
            src_rst_sync <= src_rst_meta;
        end
    end

    logic q_dst;
    always_ff @(posedge dst_clk) begin
        if (src_rst_sync) q_dst <= 1'b0;
        else              q_dst <= d_in;
    end

    assign q_out = q_dst;

endmodule
