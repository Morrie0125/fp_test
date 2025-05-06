`timescale 1ns / 1ps

module payload_loader (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [63:0] data_in,          // 每拍輸入 8 bytes
    output reg  [2:0]  mem_addr,         // memory address 0~7
    output reg         mem_rd_en,       // memory read enable
    output reg         ready,           // payload 完成 flag
    output reg [1023:0] input_vec_flat  // 展平的 64 個 FP16 數（64 * 16 bits）
);

    reg [2:0] read_ptr;
    reg       loading;
    reg       wait_ready;

    // Byte to FP16 converter (無修改)
    function [15:0] byte_to_fp16;
        input [7:0] bin;
        reg [3:0] pos;
        reg [4:0] exp;
        reg [9:0] mts;
        reg [7:0] temp;
        begin
            if (bin == 8'b0) begin
                byte_to_fp16 = 16'b0;
            end else begin
                if (bin[7]) pos = 7;
                else if (bin[6]) pos = 6;
                else if (bin[5]) pos = 5;
                else if (bin[4]) pos = 4;
                else if (bin[3]) pos = 3;
                else if (bin[2]) pos = 2;
                else if (bin[1]) pos = 1;
                else pos = 0;

                exp = pos + 5'd15;
                temp = bin - (8'd1 << pos);
                mts = temp << (10 - pos);
                byte_to_fp16 = {1'b0, exp, mts};
            end
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            read_ptr       <= 0;
            mem_rd_en      <= 0;
            mem_addr       <= 0;
            ready          <= 0;
            loading        <= 0;
            wait_ready     <= 0;
            input_vec_flat <= 0;
        end else begin
            ready <= 0;

            if (start && !loading) begin
                loading    <= 1;
                mem_rd_en  <= 1;
                mem_addr   <= 0;
                read_ptr   <= 0;
            end else if (loading) begin
                case (read_ptr)
                    3'd0: begin
                        input_vec_flat[  15:   0] <= byte_to_fp16(data_in[7:0]);
                        input_vec_flat[  31:  16] <= byte_to_fp16(data_in[15:8]);
                        input_vec_flat[  47:  32] <= byte_to_fp16(data_in[23:16]);
                        input_vec_flat[  63:  48] <= byte_to_fp16(data_in[31:24]);
                        input_vec_flat[  79:  64] <= byte_to_fp16(data_in[39:32]);
                        input_vec_flat[  95:  80] <= byte_to_fp16(data_in[47:40]);
                        input_vec_flat[ 111:  96] <= byte_to_fp16(data_in[55:48]);
                        input_vec_flat[ 127: 112] <= byte_to_fp16(data_in[63:56]);
                    end
                    3'd1: begin
                        input_vec_flat[ 143: 128] <= byte_to_fp16(data_in[7:0]);
                        input_vec_flat[ 159: 144] <= byte_to_fp16(data_in[15:8]);
                        input_vec_flat[ 175: 160] <= byte_to_fp16(data_in[23:16]);
                        input_vec_flat[ 191: 176] <= byte_to_fp16(data_in[31:24]);
                        input_vec_flat[ 207: 192] <= byte_to_fp16(data_in[39:32]);
                        input_vec_flat[ 223: 208] <= byte_to_fp16(data_in[47:40]);
                        input_vec_flat[ 239: 224] <= byte_to_fp16(data_in[55:48]);
                        input_vec_flat[ 255: 240] <= byte_to_fp16(data_in[63:56]);
                    end
                    3'd2: begin
                        input_vec_flat[ 271: 256] <= byte_to_fp16(data_in[7:0]);
                        input_vec_flat[ 287: 272] <= byte_to_fp16(data_in[15:8]);
                        input_vec_flat[ 303: 288] <= byte_to_fp16(data_in[23:16]);
                        input_vec_flat[ 319: 304] <= byte_to_fp16(data_in[31:24]);
                        input_vec_flat[ 335: 320] <= byte_to_fp16(data_in[39:32]);
                        input_vec_flat[ 351: 336] <= byte_to_fp16(data_in[47:40]);
                        input_vec_flat[ 367: 352] <= byte_to_fp16(data_in[55:48]);
                        input_vec_flat[ 383: 368] <= byte_to_fp16(data_in[63:56]);
                    end
                    3'd3: begin
                        input_vec_flat[ 399: 384] <= byte_to_fp16(data_in[7:0]);
                        input_vec_flat[ 415: 400] <= byte_to_fp16(data_in[15:8]);
                        input_vec_flat[ 431: 416] <= byte_to_fp16(data_in[23:16]);
                        input_vec_flat[ 447: 432] <= byte_to_fp16(data_in[31:24]);
                        input_vec_flat[ 463: 448] <= byte_to_fp16(data_in[39:32]);
                        input_vec_flat[ 479: 464] <= byte_to_fp16(data_in[47:40]);
                        input_vec_flat[ 495: 480] <= byte_to_fp16(data_in[55:48]);
                        input_vec_flat[ 511: 496] <= byte_to_fp16(data_in[63:56]);
                    end
                    3'd4: begin
                        input_vec_flat[ 527: 512] <= byte_to_fp16(data_in[7:0]);
                        input_vec_flat[ 543: 528] <= byte_to_fp16(data_in[15:8]);
                        input_vec_flat[ 559: 544] <= byte_to_fp16(data_in[23:16]);
                        input_vec_flat[ 575: 560] <= byte_to_fp16(data_in[31:24]);
                        input_vec_flat[ 591: 576] <= byte_to_fp16(data_in[39:32]);
                        input_vec_flat[ 607: 592] <= byte_to_fp16(data_in[47:40]);
                        input_vec_flat[ 623: 608] <= byte_to_fp16(data_in[55:48]);
                        input_vec_flat[ 639: 624] <= byte_to_fp16(data_in[63:56]);
                    end
                    3'd5: begin
                        input_vec_flat[ 655: 640] <= byte_to_fp16(data_in[7:0]);
                        input_vec_flat[ 671: 656] <= byte_to_fp16(data_in[15:8]);
                        input_vec_flat[ 687: 672] <= byte_to_fp16(data_in[23:16]);
                        input_vec_flat[ 703: 688] <= byte_to_fp16(data_in[31:24]);
                        input_vec_flat[ 719: 704] <= byte_to_fp16(data_in[39:32]);
                        input_vec_flat[ 735: 720] <= byte_to_fp16(data_in[47:40]);
                        input_vec_flat[ 751: 736] <= byte_to_fp16(data_in[55:48]);
                        input_vec_flat[ 767: 752] <= byte_to_fp16(data_in[63:56]);
                    end
                    3'd6: begin
                        input_vec_flat[ 783: 768] <= byte_to_fp16(data_in[7:0]);
                        input_vec_flat[ 799: 784] <= byte_to_fp16(data_in[15:8]);
                        input_vec_flat[ 815: 800] <= byte_to_fp16(data_in[23:16]);
                        input_vec_flat[ 831: 816] <= byte_to_fp16(data_in[31:24]);
                        input_vec_flat[ 847: 832] <= byte_to_fp16(data_in[39:32]);
                        input_vec_flat[ 863: 848] <= byte_to_fp16(data_in[47:40]);
                        input_vec_flat[ 879: 864] <= byte_to_fp16(data_in[55:48]);
                        input_vec_flat[ 895: 880] <= byte_to_fp16(data_in[63:56]);
                    end
                    3'd7: begin
                        input_vec_flat[ 911: 896] <= byte_to_fp16(data_in[7:0]);
                        input_vec_flat[ 927: 912] <= byte_to_fp16(data_in[15:8]);
                        input_vec_flat[ 943: 928] <= byte_to_fp16(data_in[23:16]);
                        input_vec_flat[ 959: 944] <= byte_to_fp16(data_in[31:24]);
                        input_vec_flat[ 975: 960] <= byte_to_fp16(data_in[39:32]);
                        input_vec_flat[ 991: 976] <= byte_to_fp16(data_in[47:40]);
                        input_vec_flat[1007: 992] <= byte_to_fp16(data_in[55:48]);
                        input_vec_flat[1023:1008] <= byte_to_fp16(data_in[63:56]);
                    end
                endcase

                read_ptr <= read_ptr + 1;
                mem_addr <= read_ptr + 1;

                if (read_ptr == 3'd7) begin
                    mem_rd_en  <= 0;
                    loading    <= 0;
                    wait_ready <= 1;
                end
            end

            if (wait_ready) begin
                wait_ready <= 0;
                ready <= 1;
            end
        end
    end

endmodule
