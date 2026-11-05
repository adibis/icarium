// CDC-026: nested clock muxes. The union still resolves, but
// mode conditions past the outer select stay unrecorded, and
// the ledger says so instead of guessing.
module note_nested_mux (
    input  logic ca,
    input  logic cb,
    input  logic s1,
    input  logic s2,
    input  logic d,
    output logic q
);

    logic inner;
    always_comb begin
        inner = s1 ? cb : ca;
    end

    logic mclk;
    always_comb begin
        mclk = s2 ? inner : ca;
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
