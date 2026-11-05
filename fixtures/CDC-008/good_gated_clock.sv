module good_gated_clock (
    input  logic clk,
    input  logic en,
    input  logic d,
    output logic q
);
  logic gclk, dst_q;

  assign gclk = clk & en;
  always_ff @(posedge gclk) dst_q <= d;
  assign q = dst_q;
endmodule
