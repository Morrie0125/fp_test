`timescale 1ns / 1ps

module tb_payload_loader;

    reg clk = 0;
    reg rst;
    reg start;
    reg [63:0] data_in;
    wire [2:0] mem_addr;
    wire mem_rd_en;
    wire ready;

    wire drop;
    // Instantiate DUT
    payload_loader uut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .data_in(data_in),
        .mem_addr(mem_addr),
        .mem_rd_en(mem_rd_en),
        .ready(ready),
        .input_vec_flat(input_vec_flat)
    );
	wire [1023:0] input_vec_flat;
	wire [15:0] test;
	wire [7:0] out0, out1, out2, out3;
    neural_pipeline uut1 (
        .clk(clk),
        .rst(rst),
        .start(ready),
        .input_vec(input_vec_flat),
        .done(done),
        .out0(out0),
        .out1(out1),
        .out2(out2),
        .out3(out3),
		  .test(test)
    );
    bloom_filter uut2 (
	.rst(rst),
	.neural_done(done),
	.idx0(out0),
	.idx1(out1),
	.idx2(out2),
	.idx3(out3),
	.is_bad(drop)
    );

    // Clock generation: 10ns period
    always #5 clk = ~clk;

    // 64 bytes of data
    reg [7:0] packet_data [0:63];
    reg [2:0] read_index;

    initial begin
        // Initialize packet data
        packet_data[ 0]=8'd39;  packet_data[ 1]=8'd110; packet_data[ 2]=8'd109; packet_data[ 3]=8'd97;
packet_data[ 4]=8'd112; packet_data[ 5]=8'd39;  packet_data[ 6]=8'd32;  packet_data[ 7]=8'd105;
packet_data[ 8]=8'd115; packet_data[ 9]=8'd32;  packet_data[10]=8'd110; packet_data[11]=8'd111;
packet_data[12]=8'd116; packet_data[13]=8'd32;  packet_data[14]=8'd114; packet_data[15]=8'd101;
packet_data[16]=8'd99;  packet_data[17]=8'd111; packet_data[18]=8'd103; packet_data[19]=8'd110;
packet_data[20]=8'd105; packet_data[21]=8'd122; packet_data[22]=8'd101; packet_data[23]=8'd100;
packet_data[24]=8'd32;  packet_data[25]=8'd97;  packet_data[26]=8'd115; packet_data[27]=8'd32;
packet_data[28]=8'd97;  packet_data[29]=8'd110; packet_data[30]=8'd32;  packet_data[31]=8'd105;
packet_data[32]=8'd110; packet_data[33]=8'd116; packet_data[34]=8'd101; packet_data[35]=8'd114;
packet_data[36]=8'd110; packet_data[37]=8'd97;  packet_data[38]=8'd108; packet_data[39]=8'd32;
packet_data[40]=8'd111; packet_data[41]=8'd114; packet_data[42]=8'd32;  packet_data[43]=8'd101;
packet_data[44]=8'd120; packet_data[45]=8'd116; packet_data[46]=8'd101; packet_data[47]=8'd114;
packet_data[48]=8'd110; packet_data[49]=8'd97;  packet_data[50]=8'd108; packet_data[51]=8'd32;
packet_data[52]=8'd99;  packet_data[53]=8'd111; packet_data[54]=8'd109; packet_data[55]=8'd109;
packet_data[56]=8'd97;  packet_data[57]=8'd110; packet_data[58]=8'd100; packet_data[59]=8'd44;
packet_data[60]=8'd13;  packet_data[61]=8'd10;  packet_data[62]=8'd111; packet_data[63]=8'd112;

    end

    // Memory feeding logic
    always @(posedge clk) begin
        if (mem_rd_en) begin
            data_in <= {
                packet_data[read_index*8 + 7],
                packet_data[read_index*8 + 6],
                packet_data[read_index*8 + 5],
                packet_data[read_index*8 + 4],
                packet_data[read_index*8 + 3],
                packet_data[read_index*8 + 2],
                packet_data[read_index*8 + 1],
                packet_data[read_index*8 + 0]
            };
            read_index <= read_index + 1;
        end
    end
	integer i;
    initial begin
	
        // Reset and start
        rst = 1;
        start = 0;
        read_index = 1;
        data_in = 64'b0;

        #20 rst = 0;
	data_in <= {
    packet_data[7], packet_data[6], packet_data[5], packet_data[4],
    packet_data[3], packet_data[2], packet_data[1], packet_data[0]
};
        #10 start = 1;
        #10 start = 0;

        // Wait for ready
        wait (ready);
	
        $display("=== Payload FP16 Output ===");
        for (i = 0; i < 64; i = i + 1) begin
            $display("input_vec_flat[%0d] = %h", i, input_vec_flat[i*16 +: 16]);
        end
	wait (done);
        $display("Result: %d %d %d %d", out0, out1, out2, out3);
	$display(drop);
        $display("\n===== Test Finished =====\n");

    end

endmodule
