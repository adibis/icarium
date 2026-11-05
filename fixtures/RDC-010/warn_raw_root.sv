// RDC-010: one consumer takes the synchronized reset while its
// sibling on the same clock uses the raw root. The sibling's
// release runs ahead; human review decides intent (warn).
module warn_raw_root (
    input  wire clk,
    input  wire rst_n,
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

    reg q_sync;
    always_ff @(posedge clk or negedge s2) begin
        if (!s2) q_sync <= 1'b0;
        else     q_sync <= d;
    end

    reg q_raw;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) q_raw <= 1'b0;
        else        q_raw <= d;
    end

    assign q = q_sync ^ q_raw;
endmodule
