module good_same_domain (
    input  logic ca,
    input  logic cb,
    input  logic p1,
    input  logic p2,
    output logic q
);
  logic s1_q, s2_q;

  always_ff @(posedge cb) s1_q <= p1 & p2;
  always_ff @(posedge cb) s2_q <= s1_q;
  assign q = s2_q;
endmodule
