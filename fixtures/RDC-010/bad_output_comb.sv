// RDC-010: a gate edits the synchronizer output before the
// consumer. The chain shaped the edge; the gate skews it.
module bad_output_comb (
    input  wire clk,
    input  wire rst_n,
    input  wire en,
    input  wire d,
    output wire q
);
    reg s1, s2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) s1 <= 1'b0;
        else        s1 <= 1'b1;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) s2 <= 1'b0;
        else        s2 <= s1;
    end

    wire gated = s2 & en;

    reg qq;
    always_ff @(posedge clk or negedge gated) begin
        if (!gated) qq <= 1'b0;
        else        qq <= d;
    end

    assign q = qq;
endmodule
