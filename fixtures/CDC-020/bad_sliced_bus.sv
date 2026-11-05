// CDC-020: a true 4-bit register sliced into wires, each lane
// 2FF-synced apart and recombined. Every crossing is width 1,
// so CDC-004 misses the bus the lanes still form together.
module bad_sliced_bus (
    input  logic       src_clk,
    input  logic       dst_clk,
    input  logic [3:0] d_in,
    output logic [3:0] data_dst
);

    logic [3:0] data;
    always_ff @(posedge src_clk) data <= d_in;

    logic d0, d1, d2, d3;
    assign d0 = data[0];
    assign d1 = data[1];
    assign d2 = data[2];
    assign d3 = data[3];

    logic d0_m, d0_s, d1_m, d1_s, d2_m, d2_s, d3_m, d3_s;
    always_ff @(posedge dst_clk) begin
        d0_m <= d0; d0_s <= d0_m;
        d1_m <= d1; d1_s <= d1_m;
        d2_m <= d2; d2_s <= d2_m;
        d3_m <= d3; d3_s <= d3_m;
    end

    assign data_dst = {d3_s, d2_s, d1_s, d0_s};

endmodule
