module good_port_select (
    input  logic ca,
    input  logic cb,
    input  logic sel,
    input  logic d,
    output logic q
);
  logic gclk, src_q, f_q, s_q;

  assign gclk = sel ? ca : cb;
  always_ff @(posedge ca) src_q <= d;
  always_ff @(posedge gclk) f_q <= src_q;
  always_ff @(posedge gclk) s_q <= f_q;
  assign q = s_q;
endmodule
