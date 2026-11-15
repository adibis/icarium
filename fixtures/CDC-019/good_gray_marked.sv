// CDC-019 silent: a 4-bit gray counter, stepping from reset, is
// registered lane by lane and each lane crosses on its own chain,
// the same shape CDC-019 reports. The user vouches coherence on the
// registering flops; one marked lane silences the group.
module good_gray_marked (
    input  logic       src_clk,
    input  logic       dst_clk,
    input  logic       rst,
    output logic [3:0] sync_out
);
    logic [3:0] bin;
    logic [3:0] gray;
    always_ff @(posedge src_clk) bin <= rst ? 4'd0 : bin + 4'd1;
    assign gray = bin ^ (bin >> 1);

    (* cdc_gray *) logic d0, d1, d2, d3;
    always_ff @(posedge src_clk) begin
        d0 <= gray[0];
        d1 <= gray[1];
        d2 <= gray[2];
        d3 <= gray[3];
    end

    logic d0_m, d0_s, d1_m, d1_s, d2_m, d2_s, d3_m, d3_s;
    always_ff @(posedge dst_clk) begin
        d0_m <= d0; d0_s <= d0_m;
        d1_m <= d1; d1_s <= d1_m;
        d2_m <= d2; d2_s <= d2_m;
        d3_m <= d3; d3_s <= d3_m;
    end
    assign sync_out = {d3_s, d2_s, d1_s, d0_s};
endmodule
