module good_single_chain (
    input  logic ca,
    input  logic cb,
    input  logic d,
    output logic q
);
  logic src_q, s1_q, s2_q;

  always_ff @(posedge ca) src_q <= d;
  always_ff @(posedge cb) s1_q <= src_q;
  always_ff @(posedge cb) s2_q <= s1_q;
  assign q = s2_q;
endmodule
