// CDC-026: plain async crossing with a 2FF synchronizer and no
// clock mux anywhere. The multclock ledger must stay silent.
module good_plain_crossing (
    input  logic ca,
    input  logic cb,
    input  logic d,
    output logic q
);

    logic src_q;
    always_ff @(posedge ca) begin
        src_q <= d;
    end

    logic sync_1;
    always_ff @(posedge cb) begin
        sync_1 <= src_q;
    end

    logic sync_2;
    always_ff @(posedge cb) begin
        sync_2 <= sync_1;
    end

    assign q = sync_2;

endmodule
