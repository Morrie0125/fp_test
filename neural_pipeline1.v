`timescale 1ns/1ps
/* ============================================================
 * neural_pipeline.v   (Block‑RAM 版本，可直接綜合到 FPGA)
 *   FC1 (64×16) + ReLU + FC2 (16×4) 推論管線
 *   – 4‑lane fp16_mac 共用流水
 *   – 權重與 bias 透過 Xilinx CoreGen 產生的 Block‑ROM 初始化
 * ------------------------------------------------------------
 * 2025‑05‑04
 * ============================================================
 */
module neural_pipeline (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [1023:0] input_vec,  // 64 × FP16
    output reg          done,
    output reg  [7:0]   out0, out1, out2, out3,
    output wire [15:0]  test         // 觀察 fc1_weight[0] 內容
);

    /* ──────────────── FSM encoding ──────────────── */
    localparam IDLE           = 5'd0 ,
               LOAD           = 5'd1 ,
               FC1_MAC        = 5'd2 ,
               FC1_WAIT       = 5'd3 ,
               FC1_ACC        = 5'd4 ,
               FC1_BIAS       = 5'd5 ,
               FC1_BIAS_WAIT  = 5'd6 ,
               FC1_BIAS_ACC   = 5'd7 ,
               RELU           = 5'd8 ,
               FC2_MAC        = 5'd9 ,
               FC2_WAIT       = 5'd10,
               FC2_ACC        = 5'd11,
               FC2_BIAS       = 5'd12,
               FC2_BIAS_WAIT  = 5'd13,
               FC2_BIAS_ACC   = 5'd14,
               FC2_DONE       = 5'd15;

    reg [4:0] state, next_state;

    /* ──────────────── 資料暫存 ──────────────── */
    reg [15:0] in_reg   [0:63];
    reg [15:0] fc1_acc  [0:15];
    reg [15:0] relu_out [0:15];
    reg [15:0] fc2_acc  [0:3];

    reg [1:0] group_idx, bias_group_idx;
    reg [5:0] mac_idx;
    reg [4:0] fc2_mac_idx;
    reg [2:0] wait_counter;

    /* ──────────────── Block‑ROM instance ────────────────
     * (1) fc1_weight : 1024 words  – 取 4 份並列供 4 lane
     * (2) fc1_bias   :   16 words  – 單埠
     * (3) fc2_weight :   64 words  – 取 4 份並列
     * (4) fc2_bias   :    4 words  – 單埠
     * -------------------------------------------------- */

    /* -- fc1 weight (4 copy) ---------------------------------- */
    reg  [9:0] fc1_w_addr0, fc1_w_addr1, fc1_w_addr2, fc1_w_addr3;
    wire [15:0] fc1_w_dout0, fc1_w_dout1, fc1_w_dout2, fc1_w_dout3;
	 wire vcc = 1'b1;
    fc1_weight u_fc1_w0 (.clka(clk),  .addra(fc1_w_addr0), .douta(fc1_w_dout0), .clkb(clk), .addrb(fc1_w_addr1), .doutb(fc1_w_dout1));
    fc1_weight u_fc1_w2 (.clka(clk),  .addra(fc1_w_addr2), .douta(fc1_w_dout2), .clkb(clk), .addrb(fc1_w_addr3), .doutb(fc1_w_dout3));

    /* -- fc1 bias --------------------------------------------- */
    reg  [3:0] fc1_b_addr;
    wire [15:0] fc1_b_dout;
    fc1_bias   u_fc1_bias (.clka(clk), .addra(fc1_b_addr), .douta(fc1_b_dout), .clkb(clk), .addrb(fc1_bias_addrb), .doutb(fc1_bias_doutb));
	 reg [9:0] fc1_bias_addrb;
	 wire [15:0] fc1_bias_doutb;
	 
    /* -- fc2 weight (4 copy) ---------------------------------- */
    reg  [5:0] fc2_w_addr0, fc2_w_addr1, fc2_w_addr2, fc2_w_addr3;
    wire [15:0] fc2_w_dout0, fc2_w_dout1, fc2_w_dout2, fc2_w_dout3;

    fc2_weight u_fc2_w0 (.clka(clk), .addra(fc2_w_addr0), .douta(fc2_w_dout0), .clkb(clk), .addrb(fc2_w_addr1), .doutb(fc2_w_dout1));
    fc2_weight u_fc2_w2 (.clka(clk), .addra(fc2_w_addr2), .douta(fc2_w_dout2), .clkb(clk), .addrb(fc2_w_addr4), .doutb(fc2_w_dout4));
  

    /* -- fc2 bias --------------------------------------------- */
    reg  [1:0] fc2_b_addr;
    wire [15:0] fc2_b_dout;
    fc2_bias   u_fc2_bias (.clka(clk), .addra(fc2_b_addr), .douta(fc2_b_dout), .clkb(clk), .addrb(fc2_bias_addrb), .doutb(fc2_bias_doutb));
	 reg [9:0] fc2_bias_addrb;
	 wire [15:0] fc2_bias_doutb;
	 
    /* 方便觀察：當 addr0==0 時 latch weight0 作為 test 輸出 */
    reg [15:0] fc1_weight0_reg;
    always @(posedge clk) begin
        if (fc1_w_addr0 == 10'd0)
            fc1_weight0_reg <= fc1_w_dout0;
    end
    assign test = fc1_weight0_reg;

    /* ──────────────── four‑lane MAC ──────────────── */
    wire [15:0] mac_out0, mac_out1, mac_out2, mac_out3;
    reg  [15:0] mac_a0, mac_a1, mac_a2, mac_a3;
    reg  [15:0] mac_b0, mac_b1, mac_b2, mac_b3;
    reg  [15:0] mac_acc_in0, mac_acc_in1, mac_acc_in2, mac_acc_in3;

    fp16_mac mac0 (.clk(clk), .rst(rst),
                   .mul_in1(mac_a0), .mul_in2(mac_b0),
                   .acc_in(mac_acc_in0), .mac_out(mac_out0));
    fp16_mac mac1 (.clk(clk), .rst(rst),
                   .mul_in1(mac_a1), .mul_in2(mac_b1),
                   .acc_in(mac_acc_in1), .mac_out(mac_out1));
    fp16_mac mac2 (.clk(clk), .rst(rst),
                   .mul_in1(mac_a2), .mul_in2(mac_b2),
                   .acc_in(mac_acc_in2), .mac_out(mac_out2));
    fp16_mac mac3 (.clk(clk), .rst(rst),
                   .mul_in1(mac_a3), .mul_in2(mac_b3),
                   .acc_in(mac_acc_in3), .mac_out(mac_out3));

    /* ──────────────── FSM register ──────────────── */
    always @(posedge clk or posedge rst)
        if (rst) state <= IDLE;
        else     state <= next_state;

    /* ──────────────── Next‑state combo ───────────── */
    always @(*) begin
        case (state)
            IDLE          : next_state = start ? LOAD : IDLE;
            LOAD          : next_state = FC1_MAC;
            FC1_MAC       : next_state = FC1_WAIT;
            FC1_WAIT      : next_state = (wait_counter==3'd6) ? FC1_ACC : FC1_WAIT;
            FC1_ACC       : next_state = (group_idx==2'd3 && mac_idx==6'd63) ? FC1_BIAS : FC1_MAC;
            FC1_BIAS      : next_state = FC1_BIAS_WAIT;
            FC1_BIAS_WAIT : next_state = (wait_counter==3'd6) ? FC1_BIAS_ACC : FC1_BIAS_WAIT;
            FC1_BIAS_ACC  : next_state = (bias_group_idx==2'd3) ? RELU : FC1_BIAS;
            RELU          : next_state = FC2_MAC;
            FC2_MAC       : next_state = FC2_WAIT;
            FC2_WAIT      : next_state = (wait_counter==3'd6) ? FC2_ACC : FC2_WAIT;
            FC2_ACC       : next_state = (fc2_mac_idx==5'd15)  ? FC2_BIAS : FC2_MAC;
            FC2_BIAS      : next_state = FC2_BIAS_WAIT;
            FC2_BIAS_WAIT : next_state = (wait_counter==3'd6) ? FC2_BIAS_ACC : FC2_BIAS_WAIT;
            FC2_BIAS_ACC  : next_state = FC2_DONE;
            FC2_DONE      : next_state = IDLE;
            default       : next_state = IDLE;
        endcase
    end

    /* ──────────────── LOAD：搬 in_vec ➜ in_reg ───────────── */
    genvar gi;
    generate
        for (gi=0; gi<64; gi=gi+1) begin : G_LOAD_IN
            always @(posedge clk) begin
                if (state==LOAD)
                    in_reg[gi] <= input_vec[16*gi +: 16];
            end
        end
    endgenerate

    /* ──────────────── ReLU pipe ───────────── */
    generate
        for (gi=0; gi<16; gi=gi+1) begin : G_RELU
            always @(posedge clk) begin
                if (state==RELU)
                    relu_out[gi] <= fc1_acc[gi][15] ? 16'd0 : fc1_acc[gi];
            end
        end
    endgenerate

    /* ──────────────── 主流水 datapath ───────────── */
    integer i;
    always @(posedge clk) begin
        case (state)
        /* --------- LOAD --------- */
        LOAD: begin
            for (i=0;i<16;i=i+1) fc1_acc[i] <= 16'd0;
            for (i=0;i<4 ;i=i+1) fc2_acc[i] <= 16'd0;
            group_idx <= 0; mac_idx <= 0;
            bias_group_idx <= 0; fc2_mac_idx <= 0;
            wait_counter <= 3'd0;
            done <= 1'b0;
        end

        /* --------- FC1_MAC : 送 address (第0拍) --------- */
        FC1_MAC: begin
            /* a = input */
            {mac_a0, mac_a1, mac_a2, mac_a3} <= {4{ in_reg[mac_idx] }};

            /* 計算四條 lane 權重 address */
            case (group_idx)
                2'd0: begin
                    fc1_w_addr0 <= 0*64 + mac_idx;
                    fc1_w_addr1 <= 1*64 + mac_idx;
                    fc1_w_addr2 <= 2*64 + mac_idx;
                    fc1_w_addr3 <= 3*64 + mac_idx;
                    {mac_acc_in0,mac_acc_in1,mac_acc_in2,mac_acc_in3} <=
                        {fc1_acc[0],fc1_acc[1],fc1_acc[2],fc1_acc[3]};
								
                end
                2'd1: begin
                    fc1_w_addr0 <= 4*64 + mac_idx;
                    fc1_w_addr1 <= 5*64 + mac_idx;
                    fc1_w_addr2 <= 6*64 + mac_idx;
                    fc1_w_addr3 <= 7*64 + mac_idx;
                    {mac_acc_in0,mac_acc_in1,mac_acc_in2,mac_acc_in3} <=
                        {fc1_acc[4],fc1_acc[5],fc1_acc[6],fc1_acc[7]};
								
                end
                2'd2: begin
                    fc1_w_addr0 <= 8*64 + mac_idx;
                    fc1_w_addr1 <= 9*64 + mac_idx;
                    fc1_w_addr2 <= 10*64+ mac_idx;
                    fc1_w_addr3 <= 11*64+ mac_idx;
                    {mac_acc_in0,mac_acc_in1,mac_acc_in2,mac_acc_in3} <=
                        {fc1_acc[ 8],fc1_acc[ 9],fc1_acc[10],fc1_acc[11]};
								
                end
                2'd3: begin
                    fc1_w_addr0 <= 12*64 + mac_idx;
                    fc1_w_addr1 <= 13*64 + mac_idx;
                    fc1_w_addr2 <= 14*64 + mac_idx;
                    fc1_w_addr3 <= 15*64 + mac_idx;
                    {mac_acc_in0,mac_acc_in1,mac_acc_in2,mac_acc_in3} <=
                        {fc1_acc[12],fc1_acc[13],fc1_acc[14],fc1_acc[15]};
								
                end
            endcase
            wait_counter <= 3'd0;
        end

        /* --------- FC1_WAIT：一拍後取到資料 --------- */
        FC1_WAIT: begin
				{mac_b0,mac_b1,mac_b2,mac_b3} <=
                {fc1_w_dout0,fc1_w_dout1,fc1_w_dout2,fc1_w_dout3};
            wait_counter <= wait_counter + 1;
        end

        /* --------- FC1_ACC：寫回 --------- */
        FC1_ACC: begin
            case (group_idx)
                2'd0: begin fc1_acc[0]<=mac_out0; fc1_acc[1]<=mac_out1;
                       fc1_acc[2]<=mac_out2; fc1_acc[3]<=mac_out3; end
                2'd1: begin fc1_acc[4]<=mac_out0; fc1_acc[5]<=mac_out1;
                       fc1_acc[6]<=mac_out2; fc1_acc[7]<=mac_out3; end
                2'd2: begin fc1_acc[ 8]<=mac_out0; fc1_acc[ 9]<=mac_out1;
                       fc1_acc[10]<=mac_out2; fc1_acc[11]<=mac_out3; end
                2'd3: begin fc1_acc[12]<=mac_out0; fc1_acc[13]<=mac_out1;
                       fc1_acc[14]<=mac_out2; fc1_acc[15]<=mac_out3; end
            endcase
            if (group_idx==2'd3) begin
                group_idx <= 0;
                mac_idx   <= mac_idx + 1;
            end else
                group_idx <= group_idx + 1;
        end

        /* --------- FC1_BIAS：送 bias address --------- */
        FC1_BIAS: begin
            fc1_b_addr <= bias_group_idx;
            {mac_b3,mac_b2,mac_b1,mac_b0} <= {4{16'h3C00}};  // 常數 1.0
            {mac_acc_in0,mac_acc_in1,mac_acc_in2,mac_acc_in3} <= {
                fc1_acc[bias_group_idx*4+0],
                fc1_acc[bias_group_idx*4+1],
                fc1_acc[bias_group_idx*4+2],
                fc1_acc[bias_group_idx*4+3]};
            wait_counter <= 3'd0;
        end
        FC1_BIAS_WAIT: begin
            {mac_a0,mac_a1,mac_a2,mac_a3} <= {fc1_b_dout,fc1_b_dout,
                                              fc1_b_dout,fc1_b_dout};
            wait_counter <= wait_counter + 1;
        end
        FC1_BIAS_ACC: begin
            fc1_acc[bias_group_idx*4+0] <= mac_out0;
            fc1_acc[bias_group_idx*4+1] <= mac_out1;
            fc1_acc[bias_group_idx*4+2] <= mac_out2;
            fc1_acc[bias_group_idx*4+3] <= mac_out3;
            bias_group_idx <= bias_group_idx + 1;
        end

        /* --------- RELU 已在 G_RELU 產生 --------- */

        /* --------- FC2_MAC：送 weight address --------- */
        FC2_MAC: begin
            {mac_a0,mac_a1,mac_a2,mac_a3} <= {4{ relu_out[fc2_mac_idx] }};
            fc2_w_addr0 <= 0*16 + fc2_mac_idx;
            fc2_w_addr1 <= 1*16 + fc2_mac_idx;
            fc2_w_addr2 <= 2*16 + fc2_mac_idx;
            fc2_w_addr3 <= 3*16 + fc2_mac_idx;
            {mac_acc_in0,mac_acc_in1,mac_acc_in2,mac_acc_in3} <=
                {fc2_acc[0],fc2_acc[1],fc2_acc[2],fc2_acc[3]};
            wait_counter <= 3'd0;
        end
        FC2_WAIT: begin
            {mac_b0,mac_b1,mac_b2,mac_b3} <=
                {fc2_w_dout0,fc2_w_dout1,fc2_w_dout2,fc2_w_dout3};
            wait_counter <= wait_counter + 1;
        end
        FC2_ACC: begin
            fc2_acc[0] <= mac_out0; fc2_acc[1] <= mac_out1;
            fc2_acc[2] <= mac_out2; fc2_acc[3] <= mac_out3;
            fc2_mac_idx <= fc2_mac_idx + 1;
        end

        /* --------- FC2_BIAS --------- */
        FC2_BIAS: begin
            fc2_b_addr <= 2'd0;                       // 四個 bias 1 CLK 同讀
            {mac_b3,mac_b2,mac_b1,mac_b0} <= {4{16'h3C00}};
            {mac_acc_in0,mac_acc_in1,mac_acc_in2,mac_acc_in3} <=
                {fc2_acc[0],fc2_acc[1],fc2_acc[2],fc2_acc[3]};
            wait_counter <= 3'd0;
        end
        FC2_BIAS_WAIT: begin
            {mac_a0,mac_a1,mac_a2,mac_a3} <= {fc2_b_dout,fc2_b_dout,
                                              fc2_b_dout,fc2_b_dout};
            wait_counter <= wait_counter + 1;
        end
        FC2_BIAS_ACC: begin
            fc2_acc[0] <= mac_out0; fc2_acc[1] <= mac_out1;
            fc2_acc[2] <= mac_out2; fc2_acc[3] <= mac_out3;
        end

        /* --------- DONE --------- */
        FC2_DONE: begin
            out0 <= FtoB(fc2_acc[0]);
            out1 <= FtoB(fc2_acc[1]);
            out2 <= FtoB(fc2_acc[2]);
            out3 <= FtoB(fc2_acc[3]);
            done <= 1'b1;
        end
        endcase
    end

    /* ─────── wait_counter default increment (FC1/FC2 *_WAIT) ─────── */
    always @(posedge clk)
        if (state==FC1_WAIT || state==FC2_WAIT ||
            state==FC1_BIAS_WAIT || state==FC2_BIAS_WAIT)
            ; /* 上面 case 裡已經 +1 */
        else
            wait_counter <= 3'd0;

    /* ──────────────── FP16 → 8‑bit helper ──────────────── */
    function [7:0] FtoB;
        input [15:0] fin;
        reg [4:0]  exp; reg [9:0] mts;
        reg signed [5:0] pos;
        reg [8:0] base,temp; reg [3:0] shift;
        reg [9:0] half,leftover; reg roundup;
    begin
        exp = fin[14:10]; mts = fin[9:0];
        if (fin==0)          FtoB = 8'd0;
        else if (exp==0)     FtoB = 8'd0;
        else if (exp==5'h1F) FtoB = 8'hFF;
        else begin
            pos = exp - 6'd15;
            if (pos<0)       temp = 0;
            else if (pos>7)  temp = 9'h1FF;
            else begin
                base   = 1 << pos;
                shift  = 10 - pos;
                temp   = base + (mts >> shift);
                leftover = mts & ((1<<shift)-1);
                half     = 1 << (shift-1);
                roundup  = (leftover>half) ? 1 :
                           (leftover<half) ? 0 : temp[0];
                temp = temp + roundup;
            end
            FtoB = (temp>9'h0FF) ? 8'hFF : temp[7:0];
        end
    end
    endfunction

endmodule
`timescale 1ns/1ps
/* ============================================================
 * neural_pipeline.v   (BlockâRAM çæ¬ï¼å¯ç´æ¥ç¶åå° FPGA)
 *   FC1 (64Ã16) + ReLU + FC2 (16Ã4) æ¨è«ç®¡ç·
 *   â 4âlane fp16_mac å±ç¨æµæ°´
 *   â æ¬éè bias éé Xilinx CoreGen ç¢çç BlockâROM åå§å
 * ------------------------------------------------------------
 * 2025â05â04
 * ============================================================
 */
module neural_pipeline (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [1023:0] input_vec,  // 64 Ã FP16
    output reg          done,
    output reg  [7:0]   out0, out1, out2, out3,
    output wire [15:0]  test         // è§å¯ fc1_weight[0] å§å®¹
);

    /* ââââââââââââââââ FSM encoding ââââââââââââââââ */
    localparam IDLE           = 5'd0 ,
               LOAD           = 5'd1 ,
               FC1_MAC        = 5'd2 ,
               FC1_WAIT       = 5'd3 ,
               FC1_ACC        = 5'd4 ,
               FC1_BIAS       = 5'd5 ,
               FC1_BIAS_WAIT  = 5'd6 ,
               FC1_BIAS_ACC   = 5'd7 ,
               RELU           = 5'd8 ,
               FC2_MAC        = 5'd9 ,
               FC2_WAIT       = 5'd10,
               FC2_ACC        = 5'd11,
               FC2_BIAS       = 5'd12,
               FC2_BIAS_WAIT  = 5'd13,
               FC2_BIAS_ACC   = 5'd14,
               FC2_DONE       = 5'd15;

    reg [4:0] state, next_state;

    /* ââââââââââââââââ è³ææ«å­ ââââââââââââââââ */
    reg [15:0] in_reg   [0:63];
    reg [15:0] fc1_acc  [0:15];
    reg [15:0] relu_out [0:15];
    reg [15:0] fc2_acc  [0:3];

    reg [1:0] group_idx, bias_group_idx;
    reg [5:0] mac_idx;
    reg [4:0] fc2_mac_idx;
    reg [2:0] wait_counter;

    /* ââââââââââââââââ BlockâROM instance ââââââââââââââââ
     * (1) fc1_weight : 1024 words  â å 4 ä»½ä¸¦åä¾ 4 lane
     * (2) fc1_bias   :   16 words  â å®å 
     * (3) fc2_weight :   64 words  â å 4 ä»½ä¸¦å
     * (4) fc2_bias   :    4 words  â å®å 
     * -------------------------------------------------- */

    /* -- fc1 weight (4 copy) ---------------------------------- */
    reg  [9:0] fc1_w_addr0, fc1_w_addr1, fc1_w_addr2, fc1_w_addr3;
    wire [15:0] fc1_w_dout0, fc1_w_dout1, fc1_w_dout2, fc1_w_dout3;
	 wire vcc = 1'b1;
    fc1_weight u_fc1_w0 (.clka(clk),  .addra(fc1_w_addr0), .douta(fc1_w_dout0), .clkb(clk), .addrb(fc1_w_addr1), .doutb(fc1_w_dout1));
    fc1_weight u_fc1_w2 (.clka(clk),  .addra(fc1_w_addr2), .douta(fc1_w_dout2), .clkb(clk), .addrb(fc1_w_addr3), .doutb(fc1_w_dout3));

    /* -- fc1 bias --------------------------------------------- */
    reg  [3:0] fc1_b_addr;
    wire [15:0] fc1_b_dout;
    fc1_bias   u_fc1_bias (.clka(clk), .addra(fc1_b_addr), .douta(fc1_b_dout), .clkb(clk), .addrb(fc1_bias_addrb), .doutb(fc1_bias_doutb));
	 reg [9:0] fc1_bias_addrb;
	 wire [15:0] fc1_bias_doutb;
	 
    /* -- fc2 weight (4 copy) ---------------------------------- */
    reg  [5:0] fc2_w_addr0, fc2_w_addr1, fc2_w_addr2, fc2_w_addr3;
    wire [15:0] fc2_w_dout0, fc2_w_dout1, fc2_w_dout2, fc2_w_dout3;

    fc2_weight u_fc2_w0 (.clka(clk), .addra(fc2_w_addr0), .douta(fc2_w_dout0), .clkb(clk), .addrb(fc2_w_addr1), .doutb(fc2_w_dout1));
    fc2_weight u_fc2_w2 (.clka(clk), .addra(fc2_w_addr2), .douta(fc2_w_dout2), .clkb(clk), .addrb(fc2_w_addr4), .doutb(fc2_w_dout4));
  

    /* -- fc2 bias --------------------------------------------- */
    reg  [1:0] fc2_b_addr;
    wire [15:0] fc2_b_dout;
    fc2_bias   u_fc2_bias (.clka(clk), .addra(fc2_b_addr), .douta(fc2_b_dout), .clkb(clk), .addrb(fc2_bias_addrb), .doutb(fc2_bias_doutb));
	 reg [9:0] fc2_bias_addrb;
	 wire [15:0] fc2_bias_doutb;
	 
    /* æ¹ä¾¿è§å¯ï¼ç¶ addr0==0 æ latch weight0 ä½çº test è¼¸åº */
    reg [15:0] fc1_weight0_reg;
    always @(posedge clk) begin
        if (fc1_w_addr0 == 10'd0)
            fc1_weight0_reg <= fc1_w_dout0;
    end
    assign test = fc1_weight0_reg;

    /* ââââââââââââââââ fourâlane MAC ââââââââââââââââ */
    wire [15:0] mac_out0, mac_out1, mac_out2, mac_out3;
    reg  [15:0] mac_a0, mac_a1, mac_a2, mac_a3;
    reg  [15:0] mac_b0, mac_b1, mac_b2, mac_b3;
    reg  [15:0] mac_acc_in0, mac_acc_in1, mac_acc_in2, mac_acc_in3;

    fp16_mac mac0 (.clk(clk), .rst(rst),
                   .mul_in1(mac_a0), .mul_in2(mac_b0),
                   .acc_in(mac_acc_in0), .mac_out(mac_out0));
    fp16_mac mac1 (.clk(clk), .rst(rst),
                   .mul_in1(mac_a1), .mul_in2(mac_b1),
                   .acc_in(mac_acc_in1), .mac_out(mac_out1));
    fp16_mac mac2 (.clk(clk), .rst(rst),
                   .mul_in1(mac_a2), .mul_in2(mac_b2),
                   .acc_in(mac_acc_in2), .mac_out(mac_out2));
    fp16_mac mac3 (.clk(clk), .rst(rst),
                   .mul_in1(mac_a3), .mul_in2(mac_b3),
                   .acc_in(mac_acc_in3), .mac_out(mac_out3));

    /* ââââââââââââââââ FSM register ââââââââââââââââ */
    always @(posedge clk or posedge rst)
        if (rst) state <= IDLE;
        else     state <= next_state;

    /* ââââââââââââââââ Nextâstate combo âââââââââââââ */
    always @(*) begin
        case (state)
            IDLE          : next_state = start ? LOAD : IDLE;
            LOAD          : next_state = FC1_MAC;
            FC1_MAC       : next_state = FC1_WAIT;
            FC1_WAIT      : next_state = (wait_counter==3'd6) ? FC1_ACC : FC1_WAIT;
            FC1_ACC       : next_state = (group_idx==2'd3 && mac_idx==6'd63) ? FC1_BIAS : FC1_MAC;
            FC1_BIAS      : next_state = FC1_BIAS_WAIT;
            FC1_BIAS_WAIT : next_state = (wait_counter==3'd6) ? FC1_BIAS_ACC : FC1_BIAS_WAIT;
            FC1_BIAS_ACC  : next_state = (bias_group_idx==2'd3) ? RELU : FC1_BIAS;
            RELU          : next_state = FC2_MAC;
            FC2_MAC       : next_state = FC2_WAIT;
            FC2_WAIT      : next_state = (wait_counter==3'd6) ? FC2_ACC : FC2_WAIT;
            FC2_ACC       : next_state = (fc2_mac_idx==5'd15)  ? FC2_BIAS : FC2_MAC;
            FC2_BIAS      : next_state = FC2_BIAS_WAIT;
            FC2_BIAS_WAIT : next_state = (wait_counter==3'd6) ? FC2_BIAS_ACC : FC2_BIAS_WAIT;
            FC2_BIAS_ACC  : next_state = FC2_DONE;
            FC2_DONE      : next_state = IDLE;
            default       : next_state = IDLE;
        endcase
    end

    /* ââââââââââââââââ LOADï¼æ¬ in_vec â in_reg âââââââââââââ */
    genvar gi;
    generate
        for (gi=0; gi<64; gi=gi+1) begin : G_LOAD_IN
            always @(posedge clk) begin
                if (state==LOAD)
                    in_reg[gi] <= input_vec[16*gi +: 16];
            end
        end
    endgenerate

    /* ââââââââââââââââ ReLU pipe âââââââââââââ */
    generate
        for (gi=0; gi<16; gi=gi+1) begin : G_RELU
            always @(posedge clk) begin
                if (state==RELU)
                    relu_out[gi] <= fc1_acc[gi][15] ? 16'd0 : fc1_acc[gi];
            end
        end
    endgenerate

    /* ââââââââââââââââ ä¸»æµæ°´ datapath âââââââââââââ */
    integer i;
    always @(posedge clk) begin
        case (state)
        /* --------- LOAD --------- */
        LOAD: begin
            for (i=0;i<16;i=i+1) fc1_acc[i] <= 16'd0;
            for (i=0;i<4 ;i=i+1) fc2_acc[i] <= 16'd0;
            group_idx <= 0; mac_idx <= 0;
            bias_group_idx <= 0; fc2_mac_idx <= 0;
            wait_counter <= 3'd0;
            done <= 1'b0;
        end

        /* --------- FC1_MAC : é address (ç¬¬0æ) --------- */
        FC1_MAC: begin
            /* a = input */
            {mac_a0, mac_a1, mac_a2, mac_a3} <= {4{ in_reg[mac_idx] }};

            /* è¨ç®åæ¢ lane æ¬é address */
            case (group_idx)
                2'd0: begin
                    fc1_w_addr0 <= 0*64 + mac_idx;
                    fc1_w_addr1 <= 1*64 + mac_idx;
                    fc1_w_addr2 <= 2*64 + mac_idx;
                    fc1_w_addr3 <= 3*64 + mac_idx;
                    {mac_acc_in0,mac_acc_in1,mac_acc_in2,mac_acc_in3} <=
                        {fc1_acc[0],fc1_acc[1],fc1_acc[2],fc1_acc[3]};
								
                end
                2'd1: begin
                    fc1_w_addr0 <= 4*64 + mac_idx;
                    fc1_w_addr1 <= 5*64 + mac_idx;
                    fc1_w_addr2 <= 6*64 + mac_idx;
                    fc1_w_addr3 <= 7*64 + mac_idx;
                    {mac_acc_in0,mac_acc_in1,mac_acc_in2,mac_acc_in3} <=
                        {fc1_acc[4],fc1_acc[5],fc1_acc[6],fc1_acc[7]};
								
                end
                2'd2: begin
                    fc1_w_addr0 <= 8*64 + mac_idx;
                    fc1_w_addr1 <= 9*64 + mac_idx;
                    fc1_w_addr2 <= 10*64+ mac_idx;
                    fc1_w_addr3 <= 11*64+ mac_idx;
                    {mac_acc_in0,mac_acc_in1,mac_acc_in2,mac_acc_in3} <=
                        {fc1_acc[ 8],fc1_acc[ 9],fc1_acc[10],fc1_acc[11]};
								
                end
                2'd3: begin
                    fc1_w_addr0 <= 12*64 + mac_idx;
                    fc1_w_addr1 <= 13*64 + mac_idx;
                    fc1_w_addr2 <= 14*64 + mac_idx;
                    fc1_w_addr3 <= 15*64 + mac_idx;
                    {mac_acc_in0,mac_acc_in1,mac_acc_in2,mac_acc_in3} <=
                        {fc1_acc[12],fc1_acc[13],fc1_acc[14],fc1_acc[15]};
								
                end
            endcase
            wait_counter <= 3'd0;
        end

        /* --------- FC1_WAITï¼ä¸æå¾åå°è³æ --------- */
        FC1_WAIT: begin
				{mac_b0,mac_b1,mac_b2,mac_b3} <=
                {fc1_w_dout0,fc1_w_dout1,fc1_w_dout2,fc1_w_dout3};
            wait_counter <= wait_counter + 1;
        end

        /* --------- FC1_ACCï¼å¯«å --------- */
        FC1_ACC: begin
            case (group_idx)
                2'd0: begin fc1_acc[0]<=mac_out0; fc1_acc[1]<=mac_out1;
                       fc1_acc[2]<=mac_out2; fc1_acc[3]<=mac_out3; end
                2'd1: begin fc1_acc[4]<=mac_out0; fc1_acc[5]<=mac_out1;
                       fc1_acc[6]<=mac_out2; fc1_acc[7]<=mac_out3; end
                2'd2: begin fc1_acc[ 8]<=mac_out0; fc1_acc[ 9]<=mac_out1;
                       fc1_acc[10]<=mac_out2; fc1_acc[11]<=mac_out3; end
                2'd3: begin fc1_acc[12]<=mac_out0; fc1_acc[13]<=mac_out1;
                       fc1_acc[14]<=mac_out2; fc1_acc[15]<=mac_out3; end
            endcase
            if (group_idx==2'd3) begin
                group_idx <= 0;
                mac_idx   <= mac_idx + 1;
            end else
                group_idx <= group_idx + 1;
        end

        /* --------- FC1_BIASï¼é bias address --------- */
        FC1_BIAS: begin
            fc1_b_addr <= bias_group_idx;
            {mac_b3,mac_b2,mac_b1,mac_b0} <= {4{16'h3C00}};  // å¸¸æ¸ 1.0
            {mac_acc_in0,mac_acc_in1,mac_acc_in2,mac_acc_in3} <= {
                fc1_acc[bias_group_idx*4+0],
                fc1_acc[bias_group_idx*4+1],
                fc1_acc[bias_group_idx*4+2],
                fc1_acc[bias_group_idx*4+3]};
            wait_counter <= 3'd0;
        end
        FC1_BIAS_WAIT: begin
            {mac_a0,mac_a1,mac_a2,mac_a3} <= {fc1_b_dout,fc1_b_dout,
                                              fc1_b_dout,fc1_b_dout};
            wait_counter <= wait_counter + 1;
        end
        FC1_BIAS_ACC: begin
            fc1_acc[bias_group_idx*4+0] <= mac_out0;
            fc1_acc[bias_group_idx*4+1] <= mac_out1;
            fc1_acc[bias_group_idx*4+2] <= mac_out2;
            fc1_acc[bias_group_idx*4+3] <= mac_out3;
            bias_group_idx <= bias_group_idx + 1;
        end

        /* --------- RELU å·²å¨ G_RELU ç¢ç --------- */

        /* --------- FC2_MACï¼é weight address --------- */
        FC2_MAC: begin
            {mac_a0,mac_a1,mac_a2,mac_a3} <= {4{ relu_out[fc2_mac_idx] }};
            fc2_w_addr0 <= 0*16 + fc2_mac_idx;
            fc2_w_addr1 <= 1*16 + fc2_mac_idx;
            fc2_w_addr2 <= 2*16 + fc2_mac_idx;
            fc2_w_addr3 <= 3*16 + fc2_mac_idx;
            {mac_acc_in0,mac_acc_in1,mac_acc_in2,mac_acc_in3} <=
                {fc2_acc[0],fc2_acc[1],fc2_acc[2],fc2_acc[3]};
            wait_counter <= 3'd0;
        end
        FC2_WAIT: begin
            {mac_b0,mac_b1,mac_b2,mac_b3} <=
                {fc2_w_dout0,fc2_w_dout1,fc2_w_dout2,fc2_w_dout3};
            wait_counter <= wait_counter + 1;
        end
        FC2_ACC: begin
            fc2_acc[0] <= mac_out0; fc2_acc[1] <= mac_out1;
            fc2_acc[2] <= mac_out2; fc2_acc[3] <= mac_out3;
            fc2_mac_idx <= fc2_mac_idx + 1;
        end

        /* --------- FC2_BIAS --------- */
        FC2_BIAS: begin
            fc2_b_addr <= 2'd0;                       // åå bias 1 CLK åè®
            {mac_b3,mac_b2,mac_b1,mac_b0} <= {4{16'h3C00}};
            {mac_acc_in0,mac_acc_in1,mac_acc_in2,mac_acc_in3} <=
                {fc2_acc[0],fc2_acc[1],fc2_acc[2],fc2_acc[3]};
            wait_counter <= 3'd0;
        end
        FC2_BIAS_WAIT: begin
            {mac_a0,mac_a1,mac_a2,mac_a3} <= {fc2_b_dout,fc2_b_dout,
                                              fc2_b_dout,fc2_b_dout};
            wait_counter <= wait_counter + 1;
        end
        FC2_BIAS_ACC: begin
            fc2_acc[0] <= mac_out0; fc2_acc[1] <= mac_out1;
            fc2_acc[2] <= mac_out2; fc2_acc[3] <= mac_out3;
        end

        /* --------- DONE --------- */
        FC2_DONE: begin
            out0 <= FtoB(fc2_acc[0]);
            out1 <= FtoB(fc2_acc[1]);
            out2 <= FtoB(fc2_acc[2]);
            out3 <= FtoB(fc2_acc[3]);
            done <= 1'b1;
        end
        endcase
    end

    /* âââââââ wait_counter default increment (FC1/FC2 *_WAIT) âââââââ */
    always @(posedge clk)
        if (state==FC1_WAIT || state==FC2_WAIT ||
            state==FC1_BIAS_WAIT || state==FC2_BIAS_WAIT)
            ; /* ä¸é¢ case è£¡å·²ç¶ +1 */
        else
            wait_counter <= 3'd0;

    /* ââââââââââââââââ FP16 â 8âbit helper ââââââââââââââââ */
    function [7:0] FtoB;
        input [15:0] fin;
        reg [4:0]  exp; reg [9:0] mts;
        reg signed [5:0] pos;
        reg [8:0] base,temp; reg [3:0] shift;
        reg [9:0] half,leftover; reg roundup;
    begin
        exp = fin[14:10]; mts = fin[9:0];
        if (fin==0)          FtoB = 8'd0;
        else if (exp==0)     FtoB = 8'd0;
        else if (exp==5'h1F) FtoB = 8'hFF;
        else begin
            pos = exp - 6'd15;
            if (pos<0)       temp = 0;
            else if (pos>7)  temp = 9'h1FF;
            else begin
                base   = 1 << pos;
                shift  = 10 - pos;
                temp   = base + (mts >> shift);
                leftover = mts & ((1<<shift)-1);
                half     = 1 << (shift-1);
                roundup  = (leftover>half) ? 1 :
                           (leftover<half) ? 0 : temp[0];
                temp = temp + roundup;
            end
            FtoB = (temp>9'h0FF) ? 8'hFF : temp[7:0];
        end
    end
    endfunction

endmodule
