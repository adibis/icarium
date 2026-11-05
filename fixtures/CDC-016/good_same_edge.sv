// CDC-016: both stages on the positive edge. Depth reads 2
// with full-period resolution, so nothing fires.
module good_same_edge (
    input  logic src_clk,
    input  logic dst_clk,
    input  logic rst_n,
    input  logic d_in,
    output logic q_out
);

    logic src_q;
    always_ff @(posedge src_clk or negedge rst_n) begin
        if (!rst_n) src_q <= 1'b0;
        else        src_q <= d_in;
    end

    logic sync_1;
    logic sync_2;
    always_ff @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_1 <= 1'b0;
            sync_2 <= 1'b0;
        end else begin
            sync_1 <= src_q;
            sync_2 <= sync_1;
        end
    end

    assign q_out = sync_2;

endmodule
