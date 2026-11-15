// CDC-010 silent: a plain clock mux whose select is a static mode
// select. The cdc_static mark is the designer's promise that it only
// changes while both clocks are stopped; icarium cannot check that.
module good_static_select (
    input  logic ca,
    input  logic cb,
    (* cdc_static *) input logic mode,
    output logic q
);
  logic gclk;
  assign gclk = mode ? cb : ca;
  always_ff @(posedge gclk) q <= !q;
endmodule
