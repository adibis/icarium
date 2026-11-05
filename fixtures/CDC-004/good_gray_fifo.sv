module good_gray_fifo (
    input  logic ca,
    input  logic cb,
    output logic [3:0] q
);
  logic [3:0] bin_q, gray_q, s1_q, s2_q;

  always_ff @(posedge ca) bin_q <= bin_q + 4'd1;
  always_ff @(posedge ca) gray_q <= bin_q ^ (bin_q >> 1);
  always_ff @(posedge cb) s1_q <= gray_q;
  always_ff @(posedge cb) s2_q <= s1_q;
  assign q = s2_q;
endmodule
