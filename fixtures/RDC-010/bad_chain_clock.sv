// RDC-010: chain runs on clk_a but serves a consumer on clk_b.
// The release edge arrives in the wrong domain (RDC-001 agrees
// on the foreign reset); the chain clock finding is RDC-010's.
module bad_chain_clock (
    input  wire clk_a,
    input  wire clk_b,
    input  wire rst_n,
    input  wire d,
    output wire q
);
    reg s1, s2;
    always_ff @(posedge clk_a or negedge rst_n) begin
        if (!rst_n) s1 <= 1'b0;
        else        s1 <= 1'b1;
    end
    always_ff @(posedge clk_a or negedge rst_n) begin
        if (!rst_n) s2 <= 1'b0;
        else        s2 <= s1;
    end

    reg qq;
    always_ff @(posedge clk_b or negedge s2) begin
        if (!s2) qq <= 1'b0;
        else     qq <= d;
    end

    assign q = qq;
endmodule
