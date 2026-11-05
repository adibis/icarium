// CDC-013: a fast toggle source into a 2FF chain with no XOR
// tail. The chain output tracks the toggle level, so two fast
// toggles between slow samples vanish without a trace.
module bad_toggle_bare (
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
    always_ff @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n) begin
            toggle_meta <= 1'b0;
            toggle_sync <= 1'b0;
        end else begin
            toggle_meta <= src_toggle;
            toggle_sync <= toggle_meta;
        end
    end

    assign event_seen = toggle_sync;

endmodule
