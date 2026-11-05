module good_mux_gated (
    input  logic ca,
    input  logic cb,
    input  logic [3:0] d,
    input  logic go,
    output logic [3:0] q
);
  logic [3:0] src_q, dst_q;
  logic en_q;

  always_ff @(posedge ca) src_q <= d;
  always_ff @(posedge cb) en_q <= go;
  always_ff @(posedge cb) dst_q <= en_q ? src_q : dst_q;
  assign q = dst_q;
endmodule
