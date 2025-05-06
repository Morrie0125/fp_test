`timescale 1ns / 1ps

module fp16_mac (
    input  wire clk,
    input  wire rst,
    input  wire [15:0] mul_in1,
    input  wire [15:0] mul_in2,
    input  wire [15:0] acc_in,
    output [15:0] mac_out
);

    // align acc_in with mul_out
    reg [15:0] acc_d1, acc_d2, acc_d3;
    wire [15:0] mul_out;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc_d1 <= 16'd0;
            acc_d2 <= 16'd0;
            acc_d3 <= 16'd0;
        end else begin
            acc_d1 <= acc_in;
            acc_d2 <= acc_d1;
            acc_d3 <= acc_d2;
        end
    end

    fp16_multiplier mul (
        .clk(clk),
        .rst(rst),
        .a(mul_in1),
        .b(mul_in2),
        .result(mul_out)
    );

    fp16_adder add (
        .clk(clk),
        .rst(rst),
        .a(mul_out),
        .b(acc_d3),
        .result(mac_out)
    );

endmodule
