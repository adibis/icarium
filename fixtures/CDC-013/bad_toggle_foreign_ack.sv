// CDC-013 fires: the toggle waits on a ready that is synchronized
// back from the destination, but from an unrelated destination flop,
// not from this crossing's own synchronizer. Nothing ties ready to
// whether the last toggle was sampled, so two fast toggles can
// still cancel between destination edges.
module bad_toggle_foreign_ack (
    input  logic src_clk,
    input  logic dst_clk,
    input  logic rst_n,
    input  logic event_in,
    input  logic dst_free,
    output logic ready,
    output logic event_seen
);

    logic dst_free_q;
    logic src_toggle;
    logic free_meta;
    logic free_sync;
    assign ready = free_sync;
    always_ff @(posedge src_clk or negedge rst_n) begin
        if (!rst_n) begin
            src_toggle <= 1'b0;
            free_meta  <= 1'b0;
            free_sync  <= 1'b0;
        end else begin
            if (event_in && ready) src_toggle <= ~src_toggle;
            free_meta <= dst_free_q;
            free_sync <= free_meta;
        end
    end

    logic toggle_meta;
    logic toggle_sync;
    logic toggle_sync_d;
    always_ff @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n) begin
            dst_free_q    <= 1'b0;
            toggle_meta   <= 1'b0;
            toggle_sync   <= 1'b0;
            toggle_sync_d <= 1'b0;
            event_seen    <= 1'b0;
        end else begin
            dst_free_q    <= dst_free;
            toggle_meta   <= src_toggle;
            toggle_sync   <= toggle_meta;
            toggle_sync_d <= toggle_sync;
            event_seen    <= toggle_sync ^ toggle_sync_d;
        end
    end

endmodule
