module good_srst_2ff (
    input  logic ca,
    input  logic cb,
    input  logic d,
    input  logic rst,
    output logic q
);
  logic src_q, s1_q, s2_q;

  always_ff @(posedge ca) src_q <= d;
  always_ff @(posedge cb) begin
    if (rst) s1_q <= 1'b0;
    else s1_q <= src_q;
  end
  always_ff @(posedge cb) begin
    if (rst) s2_q <= 1'b0;
    else s2_q <= s1_q;
  end
  assign q = s2_q;
endmodule
