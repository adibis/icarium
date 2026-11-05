// CDC-015: the same 2FF chain, but every stage takes its async
// reset from the dst-domain reset tree. Nothing fires.
module good_local_reset (
    input  logic src_clk,
    input  logic dst_clk,
    input  logic dst_rst_n,
    input  logic async_signal,
    output logic dst_q
);

    logic src_q;
    always_ff @(posedge src_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) src_q <= 1'b0;
        else            src_q <= async_signal;
    end

    logic sync_1;
    logic sync_2;
    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            sync_1 <= 1'b0;
            sync_2 <= 1'b0;
        end else begin
            sync_1 <= src_q;
            sync_2 <= sync_1;
        end
    end

    assign dst_q = sync_2;

endmodule
