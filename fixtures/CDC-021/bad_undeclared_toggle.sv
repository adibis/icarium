// CDC-021: a toggle clocked by clk_aux, which no create_clock
// declares. The domain still resolves, but every async-group
// check touching it goes blind. Only CDC-021 names the cause.
module bad_undeclared_toggle (
    input  logic clk_aux,
    output logic q_out
);

    logic q_aux;
    always_ff @(posedge clk_aux) q_aux <= ~q_aux;

    assign q_out = q_aux;

endmodule
