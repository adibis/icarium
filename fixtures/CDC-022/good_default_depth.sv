(* blackbox *)
module xpm_cdc_single #(
    parameter integer DEST_SYNC_FF   = 4,
    parameter integer INIT_SYNC_FF   = 0,
    parameter integer SIM_ASSERT_CHK = 0,
    parameter integer SRC_INPUT_REG  = 1
) (
    input  wire src_clk,
    input  wire src_in,
    input  wire dest_clk,
    output wire dest_out
);
endmodule

// CDC-022: no DEST_SYNC_FF override, so the documented default
// of 4 applies. Deep enough at a minimum of 3: silent.
module good_default_depth (
    input  wire clk_a,
    input  wire clk_b,
    input  wire flag_in,
    output wire flag_out
);
    reg flag_q;
    always_ff @(posedge clk_a) flag_q <= flag_in;

    wire flag_sync;
    xpm_cdc_single u_flag_sync (
        .src_clk (clk_a),
        .src_in  (flag_q),
        .dest_clk(clk_b),
        .dest_out(flag_sync)
    );

    reg flag_b;
    always_ff @(posedge clk_b) flag_b <= flag_sync;
    assign flag_out = flag_b;
endmodule
