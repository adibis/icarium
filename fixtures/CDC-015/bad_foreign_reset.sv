// CDC-015: a 2FF chain in dst_clk whose ARST comes from a flop
// registered in src_clk. Depth checks pass; the reset path is
// where the chain loses steady state, so RDC-001 fires on
// the same shape beside CDC-015.
// RDC-009 stays silent: the foreign reset still releases after
// the shared global root, so source data settles first.
// RDC-010 frames the reset side as a single-flop chain serving
// a foreign clock: chain-clock errors plus the record note.
module bad_foreign_reset (
    input  logic src_clk,
    input  logic dst_clk,
    input  logic global_rst_n,
    input  logic async_signal,
    output logic dst_q
);

    logic src_rst_q;
    always_ff @(posedge src_clk or negedge global_rst_n) begin
        if (!global_rst_n) src_rst_q <= 1'b0;
        else               src_rst_q <= 1'b1;
    end

    logic src_q;
    always_ff @(posedge src_clk or negedge global_rst_n) begin
        if (!global_rst_n) src_q <= 1'b0;
        else               src_q <= async_signal;
    end

    logic sync_1;
    always_ff @(posedge dst_clk or negedge src_rst_q) begin
        if (!src_rst_q) sync_1 <= 1'b0;
        else            sync_1 <= src_q;
    end

    logic sync_2;
    always_ff @(posedge dst_clk or negedge src_rst_q) begin
        if (!src_rst_q) sync_2 <= 1'b0;
        else            sync_2 <= sync_1;
    end

    assign dst_q = sync_2;

endmodule
