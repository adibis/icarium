module resets (
    input  logic clk,
    (* reset_polarity = "low" *) input logic rst_n,
    input  logic sr,
    input  logic d,
    output logic q1,
    output logic q2,
    output logic q3,
    output logic q4
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) q1 <= 0;
        else q1 <= d;
    end
    always_ff @(posedge clk) begin
        if (sr) q2 <= 0;
        else q2 <= d;
    end
    logic dmux;
    assign dmux = sr ? 1'b0 : d;
    always_ff @(posedge clk) q3 <= dmux;
    always_ff @(posedge clk) q4 <= d;
endmodule
