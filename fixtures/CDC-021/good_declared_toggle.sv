// CDC-021: the same toggle, but clk_aux is declared. The
// domain is real, so nothing fires.
module good_declared_toggle (
    input  logic clk_aux,
    output logic q_out
);

    logic q_aux;
    always_ff @(posedge clk_aux) q_aux <= ~q_aux;

    assign q_out = q_aux;

endmodule
