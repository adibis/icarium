module bad_port_two_domains (
    input  logic ca,
    input  logic cb,
    input  logic d,
    output logic qa,
    output logic qb
);
  logic fa_q, fb_q;

  always_ff @(posedge ca) fa_q <= d;
  always_ff @(posedge cb) fb_q <= d;
  assign qa = fa_q;
  assign qb = fb_q;
endmodule
