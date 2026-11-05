module negedge_clock (
    input  logic clk,
    input  logic d,
    output logic q
);
    logic nclk;
    assign nclk = ~clk;
    always_ff @(posedge nclk) q <= d;
endmodule
