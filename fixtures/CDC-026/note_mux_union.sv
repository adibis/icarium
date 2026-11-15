// CDC-026: destination clocked by a $mux union of two async
// clocks. The crossing is synchronized, so only the leg-pair
// record fires: sets, pairs, select, and chain depth.
// The select is a static mode select (cdc_static), so the runt
// hazard CDC-010 covers is out of scope for this ledger test.
module note_mux_union (
    input  logic ca,
    input  logic cb,
    (* cdc_static *) input logic sel,
    input  logic d,
    output logic q
);

    logic mclk;
    always_comb begin
        mclk = sel ? cb : ca;
    end

    logic src_q;
    always_ff @(posedge ca) begin
        src_q <= d;
    end

    logic sync_1;
    always_ff @(posedge mclk) begin
        sync_1 <= src_q;
    end

    logic sync_2;
    always_ff @(posedge mclk) begin
        sync_2 <= sync_1;
    end

    assign q = sync_2;

endmodule
