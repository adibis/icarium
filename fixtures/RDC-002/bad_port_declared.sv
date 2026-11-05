// RDC-002: the port declares active-high while the consumer
// pin expects active-low. The board follows the declaration,
// so the flop's reset never asserts.
module bad_port_declared (
    input  logic clk,
    (* reset_polarity = "high" *) input logic rst_n,
    output logic q_out
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) q_out <= 1'b0;
        else        q_out <= 1'b1;
    end

endmodule
