// CDC-023: a declared divide-by-2 ANDed with a second real
// clock. The generated leg is still a declared identity, so
// the gate declines exactly like the two-create_clock case.
module bad_generated_combine (
    input  wire clkA,
    input  wire clkB,
    input  wire din,
    output reg  q
);
  reg gdiv;
  always @(posedge clkA) gdiv <= ~gdiv;
  wire gclk = gdiv & clkB;
  always @(posedge gclk) q <= din;
endmodule
