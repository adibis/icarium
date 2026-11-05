// CDC-014: the gate feeds a second stage, but the head also
// taps out to a port. A tapped head feeds logic, not a stage:
// CDC-014 stays silent and CDC-001 frames the short chain.
module good_tapped_gate (
    input  logic src_clk,
    input  logic dst_clk,
    input  logic rst_n,
    input  logic d_in,
    input  logic mask_in,
    output logic q_out,
    output logic tap_out
);
    logic src_q;
    always_ff @(posedge src_clk or negedge rst_n) begin
        if (!rst_n) src_q <= 1'b0;
        else        src_q <= d_in;
    end

    logic mask_q;
    always_ff @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n) mask_q <= 1'b1;
        else        mask_q <= mask_in;
    end

    logic sync_1;
    always_ff @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n) sync_1 <= 1'b0;
        else        sync_1 <= src_q;
    end

    logic sync_2;
    always_ff @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n) sync_2 <= 1'b0;
        else        sync_2 <= sync_1 & mask_q;
    end

    assign q_out = sync_2;
    assign tap_out = sync_1;
endmodule
