// CDC-013 clean counterpart: the same fast-to-slow pulse
// synchronizer, closed by acknowledgement. The destination's
// synchronized toggle returns through a 2FF chain, and the source
// takes a new event only once that acknowledgement matches its own
// toggle (ready), so it never toggles twice between destination
// samples. Events offered while busy are refused, not lost.
module good_toggle_ack (
    input  logic src_clk,
    input  logic dst_clk,
    input  logic rst_n,
    input  logic event_in,
    output logic ready,
    output logic event_seen
);

    logic toggle_meta;
    logic toggle_sync;
    logic toggle_sync_d;
    logic src_toggle;
    logic ack_meta;
    logic ack_sync;
    assign ready = (src_toggle == ack_sync);
    always_ff @(posedge src_clk or negedge rst_n) begin
        if (!rst_n) begin
            src_toggle <= 1'b0;
            ack_meta   <= 1'b0;
            ack_sync   <= 1'b0;
        end else begin
            if (event_in && ready) src_toggle <= ~src_toggle;
            ack_meta <= toggle_sync;
            ack_sync <= ack_meta;
        end
    end

    always_ff @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n) begin
            toggle_meta   <= 1'b0;
            toggle_sync   <= 1'b0;
            toggle_sync_d <= 1'b0;
            event_seen    <= 1'b0;
        end else begin
            toggle_meta   <= src_toggle;
            toggle_sync   <= toggle_meta;
            toggle_sync_d <= toggle_sync;
            event_seen    <= toggle_sync ^ toggle_sync_d;
        end
    end

endmodule
