// CDC-012: a bus crossing into an OR-muxed clock (the glitch-free
// mux output shape). Union membership is unprovable per-leg, so
// the gating verdict belongs to the leg-pair report, not CDC-012.
module good_ormux_union (
    input  logic ca,
    input  logic cb,
    input  logic ena,
    input  logic enb,
    input  logic [1:0] d_in,
    output logic [1:0] q_out
);
    logic [1:0] src_q;
    always_ff @(posedge ca) begin
        src_q <= d_in;
    end

    logic g0, g1, muxclk;
    and (g0, ca, ena);
    and (g1, cb, enb);
    or (muxclk, g0, g1);

    logic [1:0] dst_q;
    always_ff @(posedge muxclk) begin
        dst_q <= src_q;
    end

    assign q_out = dst_q;
endmodule
