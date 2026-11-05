module bad_comb_before_sync (
    input  logic ca,
    input  logic cb,
    input  logic d1,
    input  logic d2,
    output logic q
);
  logic p_q, r_q, s1_q, s2_q;

  always_ff @(posedge ca) p_q <= d1;
  always_ff @(posedge ca) r_q <= d2;
  always_ff @(posedge cb) s1_q <= p_q & r_q;
  always_ff @(posedge cb) s2_q <= s1_q;
  assign q = s2_q;
endmodule
