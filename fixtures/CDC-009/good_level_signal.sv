module good_level_signal (
    input  logic fc,
    input  logic sc,
    input  logic stim,
    output logic q
);
  logic src_q, s1_q, s2_q;

  always_ff @(posedge fc) src_q <= stim;
  always_ff @(posedge sc) s1_q <= src_q;
  always_ff @(posedge sc) s2_q <= s1_q;
  assign q = s2_q;
endmodule
