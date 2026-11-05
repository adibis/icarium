module bad_clock_as_data (
    input  logic clk,
    input  logic d,
    output logic q
);
  logic div_q, dst_q;

  always_ff @(posedge clk) div_q <= ~div_q;
  always_ff @(posedge div_q) dst_q <= div_q & d;
  assign q = dst_q;
endmodule
