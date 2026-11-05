module bad_sync_missing (
    input  logic ca,
    input  logic cb,
    input  logic d,
    output logic q
);
  logic src_q, dst_q;

  always_ff @(posedge ca) src_q <= d;
  always_ff @(posedge cb) dst_q <= src_q;
  assign q = dst_q;
endmodule
