(* blackbox *)
module xpm_cdc_handshake #(
    parameter integer DEST_EXT_HSK   = 0,
    parameter integer DEST_SYNC_FF   = 4,
    parameter integer INIT_SYNC_FF   = 0,
    parameter integer SIM_ASSERT_CHK = 0,
    parameter integer SRC_SYNC_FF    = 4,
    parameter integer WIDTH          = 1
) (
    input  wire             src_clk,
    input  wire [WIDTH-1:0] src_in,
    input  wire             src_send,
    output wire             src_rcv,
    input  wire             dest_clk,
    output wire [WIDTH-1:0] dest_out,
    output wire             dest_req,
    input  wire             dest_ack
);
endmodule

// CDC-022: the destination side is deep enough, but the ack path
// declares SRC_SYNC_FF=2. The rule reads every depth parameter,
// not just the destination one.
module bad_handshake_src (
    input  wire clk_a,
    input  wire clk_b,
    input  wire flag_in,
    output wire flag_out
);
    reg flag_q;
    always_ff @(posedge clk_a) flag_q <= flag_in;

    wire src_rcv, dest_req;
    wire flag_sync;
    xpm_cdc_handshake #(
        .DEST_SYNC_FF(4),
        .SRC_SYNC_FF(2),
        .WIDTH(1)
    ) u_hs (
        .src_clk (clk_a),
        .src_in  (flag_q),
        .src_send(flag_q),
        .src_rcv (src_rcv),
        .dest_clk(clk_b),
        .dest_out(flag_sync),
        .dest_req(dest_req),
        .dest_ack(dest_req)
    );

    reg flag_b;
    always_ff @(posedge clk_b) flag_b <= flag_sync;
    assign flag_out = flag_b;
endmodule
