module single_clock (
    input  logic clk,
    input  logic d,
    output logic q
);
    logic stage;
    always_ff @(posedge clk) begin
        stage <= d;
        q <= stage;
    end
endmodule
