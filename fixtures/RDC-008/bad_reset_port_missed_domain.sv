// RDC-008: raw_rst_n has a proper chain in clk_a, proving the
// builder knows the port needs syncing, but two clk_b flops
// take the raw port with no chain in their domain. The miss,
// not the raw port alone, is the finding.
module bad_reset_port_missed_domain (
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

    always_ff @(posedge clk_a or negedge rst_a_n)
        if (!rst_a_n) q_a <= 1'b0;
        else          q_a <= d_in_a;

    logic qb_q0, qb_q1;
    always_ff @(posedge clk_b or negedge raw_rst_n) begin
        if (!raw_rst_n) begin
            qb_q0 <= 1'b0;
            qb_q1 <= 1'b0;
        end else begin
            qb_q0 <= d_in_b;
            qb_q1 <= qb_q0;
        end
    end
    assign q_b = qb_q1;

endmodule
