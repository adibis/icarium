// CDC-026: AND-OR clock mux with independent enables. Both
// legs can pass at once, so pairs stay async and the record
// names each gate. CDC-023 stays silent: the shape resolves
// to a union domain instead of leaving flops unknown.
module note_or_mux (
    input  logic ca,
    input  logic cb,
    input  logic ena,
    input  logic enb,
    input  logic d,
    output logic q
);

    logic gclk;
    always_comb begin
        gclk = (ca & ena) | (cb & enb);
    end

    logic src_q;
    always_ff @(posedge ca) begin
        src_q <= d;
    end

    logic sync_1;
    always_ff @(posedge gclk) begin
        sync_1 <= src_q;
    end

    logic sync_2;
    always_ff @(posedge gclk) begin
        sync_2 <= sync_1;
    end

    assign q = sync_2;

endmodule
