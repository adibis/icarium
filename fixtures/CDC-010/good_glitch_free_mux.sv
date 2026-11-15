// CDC-010 silent: a break-before-make glitch-free clock mux. sel
// and the other leg's enable are synchronized raw into each leg by
// two unreset flops (they flush while reset is held); only then
// are they combined, and each enable is retimed on its own clock's
// falling edge, so it changes only while that clock is low. A leg
// turns on only after it has seen the other leg off, so the output
// carries no runt pulse, provided sel holds until `on` shows the
// previous switch landed. Reset selects clk0. CDC-024 still warns:
// sel fans into both leg synchronizers, and only a human can
// confirm it is held that long.
module good_glitch_free_mux (
    input  logic clk0,
    input  logic clk1,
    input  logic rst0,
    input  logic rst1,
    input  logic cs,
    input  logic sel_d,
    output logic clk_out,
    output logic [1:0] on,
    output logic q
);
    // The select comes from a control-domain register.
    logic sel;
    always_ff @(posedge cs) sel <= sel_d;

    logic s0_m, s0_s, o1_m, o1_s, en0_q, en0_n;
    logic s1_m, s1_s, o0_m, o0_s, en1_q, en1_n;

    always_ff @(posedge clk0) begin
        s0_m <= sel;
        s0_s <= s0_m;
        o1_m <= en1_n;
        o1_s <= o1_m;
        en0_q <= rst0 ? 1'b1 : !s0_s && !o1_s;
    end
    always_ff @(negedge clk0) en0_n <= rst0 ? 1'b1 : en0_q;

    always_ff @(posedge clk1) begin
        s1_m <= sel;
        s1_s <= s1_m;
        o0_m <= en0_n;
        o0_s <= o0_m;
        en1_q <= rst1 ? 1'b0 : s1_s && !o0_s;
    end
    always_ff @(negedge clk1) en1_n <= rst1 ? 1'b0 : en1_q;

    assign clk_out = (clk0 && en0_n) || (clk1 && en1_n);
    assign on = {en1_n, en0_n};

    // A sink on the muxed clock.
    always_ff @(posedge clk_out) q <= !q;
endmodule
