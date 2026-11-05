// CDC-012: the request syncs into dst before gating the capture,
// so the bus looks gated, but the payload advances every src cycle
// while the request is in flight. Nothing holds it stable.
module bad_one_sided (
    input  logic       src_clk,
    input  logic       dst_clk,
    input  logic       rst_n,
    input  logic       src_req,
    input  logic [7:0] src_data,
    output logic [7:0] dst_data
);

    logic [7:0] src_payload;
    logic       src_req_q;
    always_ff @(posedge src_clk or negedge rst_n) begin
        if (!rst_n) begin
            src_payload <= 8'h00;
            src_req_q   <= 1'b0;
        end else begin
            src_payload <= src_data;
            src_req_q   <= src_req;
        end
    end

    logic req_meta;
    logic req_sync;
    always_ff @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n) begin
            req_meta <= 1'b0;
            req_sync <= 1'b0;
        end else begin
            req_meta <= src_req_q;
            req_sync <= req_meta;
        end
    end

    always_ff @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n)        dst_data <= 8'h00;
        else if (req_sync) dst_data <= src_payload;
    end

endmodule
