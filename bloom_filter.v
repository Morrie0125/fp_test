// bloom_filter.v
// 檢查 4 個 bit index 是否都命中 Bloom Mask

module bloom_filter (
    input rst,
    input neural_done,
    input  wire [7:0] idx0,  // index 0~511
    input  wire [7:0] idx1,
    input  wire [7:0] idx2,
    input  wire [7:0] idx3,
    output reg       is_bad // 4 個 index 全命中 = 壞封包
);

    // 512-bit Bloom Filter mask（你要用 readmemh/.mem 初始化）
    reg [511:0] mask = 512'h00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000030000000000000700060000;



    wire bit0 = mask[idx0];
    wire bit1 = mask[idx1];
    wire bit2 = mask[idx2];
    wire bit3 = mask[idx3];

    always@(*) begin
	if(rst)
	   is_bad = 0;
	else if(neural_done)
           is_bad = bit0 & bit1 & bit2 & bit3;
    end

endmodule
