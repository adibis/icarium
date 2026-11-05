module bad_port_srst (
    input  logic clk,
    input  logic d,
    input  logic rst,
    output logic q
);
  logic dst_q;

  always_ff @(posedge clk) begin
    if (rst) dst_q <= 1'b0;
    else dst_q <= d;
  end
  assign q = dst_q;
endmodule
