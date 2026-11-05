module good_slow_ratio (
    input  logic fc,
    input  logic sc,
    input  logic stim,
    output logic q
);
  logic req_q, req_d, pulse_q, s1_q, s2_q;

  always_ff @(posedge fc) req_q <= stim;
  always_ff @(posedge fc) req_d <= req_q;
  always_ff @(posedge fc) pulse_q <= req_q & ~req_d;
  always_ff @(posedge sc) s1_q <= pulse_q;
  always_ff @(posedge sc) s2_q <= s1_q;
  assign q = s2_q;
endmodule
