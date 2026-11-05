// RDC-002: declared low, wired low. Declaration and pin
// agree, so nothing fires.
module good_polarity_match (
    input  logic clk,
    (* reset_polarity = "low" *) input logic rst_n,
    output logic q_out
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) q_out <= 1'b0;
        else        q_out <= 1'b1;
    end

endmodule
