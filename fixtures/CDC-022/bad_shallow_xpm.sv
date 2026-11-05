// Blackbox stub: the macro body ships in the vendor tree, so
// the analyzer sees the instantiation, its type, and its
// parameter overrides, never the stages inside.
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

// CDC-022: the instance declares DEST_SYNC_FF=2. Under a project
// minimum of 3 that is short, and only CDC-022 can say so: the
// stages live inside the macro, past any chain walk.
module bad_shallow_xpm (
    input  wire clk_a,
    input  wire clk_b,
    input  wire flag_in,
    output wire flag_out
);
    reg flag_q;
    always_ff @(posedge clk_a) flag_q <= flag_in;

    wire flag_sync;
    xpm_cdc_single #(
        .DEST_SYNC_FF(2),
        .SRC_INPUT_REG(0)
    ) u_flag_sync (
        .src_clk (clk_a),
        .src_in  (flag_q),
        .dest_clk(clk_b),
        .dest_out(flag_sync)
    );

    reg flag_b, flag_c;
    always_ff @(posedge clk_b) begin
        flag_b <= flag_sync;
        flag_c <= flag_b;
    end
    assign flag_out = flag_c;
endmodule
