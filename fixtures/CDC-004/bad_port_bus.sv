module bad_port_bus (
    input  logic ca,
    input  logic cb,
    input  logic [3:0] d,
    output logic [3:0] q
);
  logic [3:0] dst_q;

  always_ff @(posedge cb) dst_q <= d;
  assign q = dst_q;
endmodule
