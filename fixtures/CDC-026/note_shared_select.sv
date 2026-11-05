// CDC-026: source and destination muxed by the same select.
// Cross leg-pairs can never co-occur, so the record marks
// them exclusive instead of async. CDC-006 joins in: port d
// is async to the cb leg feeding the union-clocked head.
module note_shared_select (
    input  logic ca,
    input  logic cb,
    input  logic sel,
    input  logic d,
    output logic q
);

    logic sclk;
    always_comb begin
        sclk = sel ? cb : ca;
    end

    logic dclk;
    always_comb begin
        dclk = sel ? cb : ca;
    end

    logic src_q;
    always_ff @(posedge sclk) begin
        src_q <= d;
    end

    logic sync_1;
    always_ff @(posedge dclk) begin
        sync_1 <= src_q;
    end

    logic sync_2;
    always_ff @(posedge dclk) begin
        sync_2 <= sync_1;
    end

    assign q = sync_2;

endmodule
