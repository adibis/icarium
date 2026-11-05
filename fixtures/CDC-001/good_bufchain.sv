// CDC-001: a clean 2FF chain with an explicit buffer between
// the stages, the shape slang emits on every net. The buffer
// is wire: depth reads 2 and nothing fires.
module good_bufchain (
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

    logic sync_1b;
    buf (sync_1b, sync_1);

    logic sync_2;
    always_ff @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n) sync_2 <= 1'b0;
        else        sync_2 <= sync_1b;
    end

    assign q_out = sync_2;
endmodule
