(* blackbox *)
module vendor_filter (
    input  wire sample_in,
    output wire sample_out
);
endmodule

// CDC-025: the macro output feeds a flop but carries no clock
// association; the vendor body is invisible, so the crossing
// cannot prove synchronicity. One finding names the macro.
module bad_macro_output (
    input  wire clk,
    input  wire d_in,
    output wire q
);
    wire macro_data;
    vendor_filter u_filt (
        .sample_in (d_in),
        .sample_out(macro_data)
    );

    reg q_r;
    always_ff @(posedge clk) q_r <= macro_data;
    assign q = q_r;
endmodule
