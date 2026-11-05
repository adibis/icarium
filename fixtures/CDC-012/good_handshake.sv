// CDC-012: the same gated bus, but a synced-back ack holds the
// payload: the source only loads when no request is in flight,
// so the destination always samples a matching value.
module good_handshake (
    input  logic       src_clk,
    input  logic       dst_clk,
    input  logic       rst_n,
    input  logic       src_req,
    input  logic [7:0] src_data,
    output logic [7:0] dst_data
);

    logic dst_ack;
    logic ack_meta, ack_sync;
    always_ff @(posedge src_clk or negedge rst_n) begin
        if (!rst_n) begin
            ack_meta <= 1'b0;
            ack_sync <= 1'b0;
        end else begin
            ack_meta <= dst_ack;
            ack_sync <= ack_meta;
        end
    end

    logic src_load_q;
    always_ff @(posedge src_clk or negedge rst_n) begin
        if (!rst_n)        src_load_q <= 1'b0;
        else if (src_req)  src_load_q <= 1'b1;
        else if (ack_sync) src_load_q <= 1'b0;
    end

    logic [7:0] src_payload;
    always_ff @(posedge src_clk or negedge rst_n) begin
        if (!rst_n)
            src_payload <= 8'h00;
        else if (src_req && !src_load_q && !ack_sync)
            src_payload <= src_data;
    end

    logic load_sync0, load_sync1;
    always_ff @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n) begin
            load_sync0 <= 1'b0;
            load_sync1 <= 1'b0;
            dst_ack    <= 1'b0;
            dst_data   <= 8'h00;
        end else begin
            load_sync0 <= src_load_q;
            load_sync1 <= load_sync0;
            dst_ack    <= load_sync1;
            if (load_sync1) dst_data <= src_payload;
        end
    end

endmodule
