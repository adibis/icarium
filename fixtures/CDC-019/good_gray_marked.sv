// CDC-019: the same decode, but the user vouches coherence
// on the registering flops. One marked lane silences the group.
module good_gray_marked (
    input  logic       src_clk,
    input  logic       dst_clk,
    input  logic [1:0] sel,
    output logic [3:0] sync_out
);

    logic [3:0] one_hot;
    always_comb begin
        one_hot = '0;
        one_hot[sel] = 1'b1;
    end

    (* cdc_gray *) logic d0, d1, d2, d3;
    always_ff @(posedge src_clk) begin
        d0 <= one_hot[0];
        d1 <= one_hot[1];
        d2 <= one_hot[2];
        d3 <= one_hot[3];
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
