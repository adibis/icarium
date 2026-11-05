// Good for CDC-005 (the twin chains never recombine) but bad for
// CDC-024 by design: the fanout itself still needs judgement.
module good_no_reconverge (
    input  logic ca,
    input  logic cb,
    input  logic d,
    output logic qa,
    output logic qb
);
  logic src_q, a1_q, a2_q, b1_q, b2_q;

  always_ff @(posedge ca) src_q <= d;
  always_ff @(posedge cb) a1_q <= src_q;
  always_ff @(posedge cb) a2_q <= a1_q;
  always_ff @(posedge cb) b1_q <= src_q;
  always_ff @(posedge cb) b2_q <= b1_q;
  assign qa = a2_q;
  assign qb = b2_q;
endmodule
