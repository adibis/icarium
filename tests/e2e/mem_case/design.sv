module mem_case (
    input  logic wr_clk, rd_clk,
    input  logic [3:0] waddr, raddr,
    input  logic [7:0] wdata,
    input  logic we,
    output logic [7:0] rdata
);
    logic [7:0] mem [0:15];
    always_ff @(posedge wr_clk) if (we) mem[waddr] <= wdata;
    always_ff @(posedge rd_clk) rdata <= mem[raddr];
endmodule
