module good_shared_clock (
    input  logic ca,
    input  logic cb,
    input  logic en_d,
    input  logic d,
    output logic q
);
  logic en_q, gclk, src_q, f_q, s_q;

  always_ff @(posedge cb) en_q <= en_d;
  assign gclk = en_q ? ca : cb;
  always_ff @(posedge ca) src_q <= d;
  always_ff @(posedge gclk) f_q <= src_q;
  always_ff @(posedge gclk) s_q <= f_q;
  assign q = s_q;
endmodule
