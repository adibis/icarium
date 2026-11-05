// RDC-010: single-flop reset synchronizer (the OpenTitan idiom)
// serving one consumer. Proves duty by service; note only.
module note_single_flop (
    input  wire clk,
    input  wire rst_n,
    input  wire d,
    output wire q
);
    reg rsync;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rsync <= 1'b0;
        else        rsync <= 1'b1;
    end

    reg qq;
    always_ff @(posedge clk or negedge rsync) begin
        if (!rsync) qq <= 1'b0;
        else        qq <= d;
    end

    assign q = qq;
endmodule
