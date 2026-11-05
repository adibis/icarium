module bad_bare_bus (
    input  logic ca,
    input  logic cb,
    input  logic [3:0] d,
    output logic [3:0] q
);
  logic [3:0] src_q, dst_q;

  always_ff @(posedge ca) src_q <= d;
  always_ff @(posedge cb) dst_q <= src_q;
  assign q = dst_q;
endmodule
