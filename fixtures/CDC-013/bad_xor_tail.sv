// CDC-013: a pulse synchronizer (toggle source, 2FF chain, XOR
// tail) crossing 2 ns into 20 ns. The XOR tail turns each toggle
// into one pulse, but two events between destination samples
// still cancel to no edge: only a handshake or backpressure
// closes event loss.
module bad_xor_tail (
    input  logic src_clk,
    input  logic dst_clk,
    input  logic rst_n,
    input  logic event_in,
    output logic event_seen
);

    logic src_toggle;
    always_ff @(posedge src_clk or negedge rst_n) begin
        if (!rst_n)        src_toggle <= 1'b0;
        else if (event_in) src_toggle <= ~src_toggle;
    end

    logic toggle_meta;
    logic toggle_sync;
    logic toggle_sync_d;
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
