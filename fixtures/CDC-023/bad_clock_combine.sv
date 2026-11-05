// CDC-023: two declared clocks ANDed onto one net feeding a
// flop clock. The tracer declines instead of picking a leg,
// and the rule names the gate, the net, and the clocks.
module bad_clock_combine (
    input  wire clkA,
    input  wire clkB,
    input  wire d,
    output reg  q
);
  wire gclk = clkA & clkB;
  always @(posedge gclk) q <= d;
endmodule
