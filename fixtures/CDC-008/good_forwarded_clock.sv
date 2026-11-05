module good_forwarded_clock (
    input  logic clk,
    input  logic d,
    output logic q,
    output logic clk_out
);
  logic dst_q;

  assign clk_out = clk;
  always_ff @(posedge clk) dst_q <= d;
  assign q = dst_q;
endmodule
