// RDC-004: the AND registers on clk before touching the ARST
// pin. Flop-to-flop reset drive in one domain is clean, and
// the polarities agree, so nothing fires.
module good_registered_reset (
    input  logic clk,
    input  logic global_rst_n,
    input  logic kill_a,
    input  logic kill_b,
    input  logic d_in,
    output logic q_out
);

    logic flop_a, flop_b;
    always_ff @(posedge clk or negedge global_rst_n) begin
        if (!global_rst_n) begin
            flop_a <= 1'b0;
            flop_b <= 1'b0;
        end else begin
            flop_a <= ~kill_a;
            flop_b <= ~kill_b;
        end
    end

    logic comb_rst_reg;
    always_ff @(posedge clk or negedge global_rst_n) begin
        if (!global_rst_n) comb_rst_reg <= 1'b0;
        else               comb_rst_reg <= flop_a & flop_b;
    end

    always_ff @(posedge clk or negedge comb_rst_reg) begin
        if (!comb_rst_reg) q_out <= 1'b0;
        else               q_out <= d_in;
    end

endmodule
