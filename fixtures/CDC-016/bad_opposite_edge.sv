// CDC-016: stage 1 samples on the positive edge of dst_clk,
// stage 2 on the negative edge. Depth reads 2, but each value
// gets half a period to resolve instead of a full one.
module bad_opposite_edge (
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
    always_ff @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n) sync_1 <= 1'b0;
        else        sync_1 <= src_q;
    end

    logic sync_2;
    always_ff @(negedge dst_clk or negedge rst_n) begin
        if (!rst_n) sync_2 <= 1'b0;
        else        sync_2 <= sync_1;
    end

    assign q_out = sync_2;

endmodule
