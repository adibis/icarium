module generated_clock (
    input  logic clk,
    input  logic d,
    output logic q
);
    logic div;
    logic sync;
    always_ff @(posedge clk) div <= ~div;
    always_ff @(posedge div) begin
        sync <= d;
        q <= sync;
    end
endmodule
