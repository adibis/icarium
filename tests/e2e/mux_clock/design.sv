module mux_clock (
    input  logic clk_a,
    input  logic clk_b,
    input  logic sel,
    input  logic d,
    output logic q
);
    logic mclk;
    assign mclk = sel ? clk_a : clk_b;
    always_ff @(posedge mclk) q <= d;
endmodule
