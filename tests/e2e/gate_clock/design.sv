module gate_clock (
    input  logic clk,
    input  logic en,
    input  logic d,
    output logic q
);
    logic gclk;
    assign gclk = clk & en;
    always_ff @(posedge gclk) q <= d;
endmodule
