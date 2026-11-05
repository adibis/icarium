// Reconvergent twin chains: CDC-005 proves the recombination and
// CDC-024 flags the fanout behind it. Both fire by design.
module bad_reconvergent (
    input  logic ca,
    input  logic cb,
    input  logic d,
    output logic q
);
  logic src_q, a1_q, a2_q, b1_q, b2_q, c_q;

  always_ff @(posedge ca) src_q <= d;
  always_ff @(posedge cb) a1_q <= src_q;
  always_ff @(posedge cb) a2_q <= a1_q;
  always_ff @(posedge cb) b1_q <= src_q;
  always_ff @(posedge cb) b2_q <= b1_q;
  always_ff @(posedge cb) c_q <= a2_q & b2_q;
  assign q = c_q;
endmodule
