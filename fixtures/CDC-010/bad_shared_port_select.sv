// CDC-010 fires: the select port is timed to ca, one of the muxed
// clocks, but a plain mux still switches between asynchronous
// clocks, so a switch can emit a runt pulse on the cb side.
module bad_shared_port_select (
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
