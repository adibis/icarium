// CDC-004 silent: src_q steps through the 4-bit gray sequence from
// reset by flipping one bit per clock, which no structural check
// recognizes, so the cdc_gray promise is what clears the
// single-stage crossing.
module good_marked_gray (
    input  logic ca,
    input  logic cb,
    input  logic rst,
    output logic [3:0] q
);
  (* cdc_gray *) logic [3:0] src_q;
  logic [3:0] dst_q;
  // Reflected gray increment: on even parity flip bit 0, otherwise
  // flip the bit above the lowest set bit (from 4'b1000, wrap to 0).
  always_ff @(posedge ca)
    if (rst) src_q <= 4'h0;
    else if (~^src_q) src_q[0] <= ~src_q[0];
    else if (src_q[0]) src_q[1] <= ~src_q[1];
    else if (src_q[1]) src_q[2] <= ~src_q[2];
    else src_q[3] <= ~src_q[3];
  always_ff @(posedge cb) dst_q <= src_q;
  assign q = dst_q;
endmodule
