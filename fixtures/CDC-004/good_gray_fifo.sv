// CDC-004 silent: a binary counter stepping by one from reset is
// gray-encoded into gray_q, so the bus changes one bit per source
// clock, and it crosses into a 2-deep multi-bit chain.
module good_gray_fifo (
    input  logic ca,
    input  logic cb,
    input  logic rst,
    output logic [3:0] q
);
  logic [3:0] bin_q, gray_q, s1_q, s2_q;
  always_ff @(posedge ca) bin_q <= rst ? 4'd0 : bin_q + 4'd1;
  always_ff @(posedge ca) gray_q <= rst ? 4'd0 : bin_q ^ (bin_q >> 1);
  always_ff @(posedge cb) s1_q <= gray_q;
  always_ff @(posedge cb) s2_q <= s1_q;
  assign q = s2_q;
endmodule
