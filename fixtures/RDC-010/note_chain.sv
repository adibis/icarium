// RDC-010: textbook 2FF reset synchronizer serving one consumer
// on the same clock. Clean shape; only the chain note reports.
module note_chain (
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

    reg qq;
    always_ff @(posedge clk or negedge s2) begin
        if (!s2) qq <= 1'b0;
        else     qq <= d;
    end

    assign q = qq;
endmodule
