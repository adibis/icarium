// Source for yosys-names.json, the netlist tests/ir_names_test.zig
// reads: regenerate with
//   yosys -p "read_verilog -sv tests/fixtures/names.sv; hierarchy -check -top names;
//             proc; flatten; write_json tests/fixtures/yosys-names.json"
module names_sub (input logic clk, input logic [3:0] d, output logic [3:0] q);
    logic [3:0] q_reg;
    always_ff @(posedge clk) q_reg <= d;
    assign q = q_reg;
endmodule

module names_leaf (input logic clk, input logic d, output logic q);
    always_ff @(posedge clk) q <= d;
endmodule

module names_mid (input logic clk, input logic d, output logic q);
    names_leaf u_leaf (.clk, .d, .q);
endmodule

module names (
    input  logic       ca,
    input  logic       cb,
    input  logic [3:0] din,
    input  logic       d,
    output logic [3:0] dout,
    output logic       o,
    output logic       p
);
    logic [3:0] mid;
    logic [0:3] up;
    logic       m;
    logic [7:0] bus;
    names_sub u_a (.clk(ca), .d(din), .q(mid));
    names_mid u_mid (.clk(ca), .d, .q(m));
    always_ff @(posedge cb) up <= mid;
    always_ff @(posedge cb) dout <= up;
    always_ff @(posedge cb) o <= m;
    always_ff @(posedge cb) bus[3] <= m;
    always_ff @(posedge cb) bus[5:4] <= {m, m};
    assign p = bus[3] ^ bus[4];
endmodule
