// RDC-008 clean: both domains sync the shared port through
// their own chains, and every consumer hangs off a tail Q,
// so no domain deasserts straight from the raw port.
module good_reset_port_both_domains (
    input  logic clk_a,
    input  logic clk_b,
    input  logic raw_rst_n,
    input  logic d_in_a,
    input  logic d_in_b,
    output logic q_a,
    output logic q_b
);

    logic rst_a_meta, rst_a_n;
    always_ff @(posedge clk_a or negedge raw_rst_n)
        if (!raw_rst_n) rst_a_meta <= 1'b0;
        else            rst_a_meta <= 1'b1;
    always_ff @(posedge clk_a or negedge raw_rst_n)
        if (!raw_rst_n) rst_a_n <= 1'b0;
        else            rst_a_n <= rst_a_meta;

    logic rst_b_meta, rst_b_n;
    always_ff @(posedge clk_b or negedge raw_rst_n)
        if (!raw_rst_n) rst_b_meta <= 1'b0;
        else            rst_b_meta <= 1'b1;
    always_ff @(posedge clk_b or negedge raw_rst_n)
        if (!raw_rst_n) rst_b_n <= 1'b0;
        else            rst_b_n <= rst_b_meta;

    always_ff @(posedge clk_a or negedge rst_a_n)
        if (!rst_a_n) q_a <= 1'b0;
        else          q_a <= d_in_a;

    always_ff @(posedge clk_b or negedge rst_b_n)
        if (!rst_b_n) q_b <= 1'b0;
        else          q_b <= d_in_b;

endmodule
