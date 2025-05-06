`timescale 1ns / 1ps

module fp16_multiplier (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg  [15:0] result
);

    // unpack
    wire        sig1 = a[15];
    wire        sig2 = b[15];
    wire [4:0]  exp1 = a[14:10];
    wire [4:0]  exp2 = b[14:10];
    wire [9:0]  mts1 = a[9:0];
    wire [9:0]  mts2 = b[9:0];

    reg        s1_spc;
    reg [15:0] s1_temp;
    reg [4:0]  s1_exp1_eff, s1_exp2_eff;
    reg [10:0] s1_mts1_ex, s1_mts2_ex;
    reg        s1_sig;
    
    reg [15:0] s2_temp;
    reg        s2_spc;
    reg        s2_sig;
    reg signed [6:0] s2_exp_sum;
    reg [21:0] s2_prod;
    
    reg [4:0]  final_exp;
    reg [10:0] final_mts;
    reg [21:0] prod_norm;
    reg [4:0]  shift;
    reg        guard, round, sticky;
    reg signed [6:0] adjusted_exp;
    
    wire        final_sig = sig1^sig2;
    
    // 1st stage: special case check
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s1_spc <= 1'b0;
            s1_temp <= 16'd0;
            s1_exp1_eff <= 5'd0;
            s1_exp2_eff <= 5'd0;
            s1_mts1_ex <= 11'd0;
            s1_mts2_ex <= 11'd0;
            s1_sig <= 1'b0;
        end 
        else begin
            // nan in, nan out
            if ((exp1 == 5'b11111 && mts1 != 0) || (exp2 == 5'b11111 && mts2 != 0)) begin
                s1_spc  <= 1'b1;
                s1_temp <= 16'h7FFF;
            end 
            // inf * 0 , nan out
            else if (((exp1 == 5'b11111 && mts1 == 0) && (exp2 == 0 && mts2 == 0)) ||
                    ((exp2 == 5'b11111 && mts2 == 0) && (exp1 == 0 && mts1 == 0))) begin
                s1_spc  <= 1'b1;
                s1_temp <= 16'h7FFF; 
            end 
            // inf in, inf out
            else if (exp1 == 5'b11111 || exp2 == 5'b11111) begin
                s1_spc  <= 1'b1;
                s1_temp <= {final_sig, 5'b11111, 10'd0}; 
            end 
            // zero in, zero out
            else if ((exp1 == 0 && mts1 == 0) || (exp2 == 0 && mts2 == 0)) begin
                s1_spc  <= 1'b1;
                s1_temp <= {final_sig, 5'd0, 10'd0}; 
            end 
            else begin
                s1_spc <= 1'b0;
                s1_temp <= 16'd0;
                // set eff exp for denormal in
                s1_exp1_eff <= (exp1 == 0) ? 5'd1 : exp1;
                s1_exp2_eff <= (exp2 == 0) ? 5'd1 : exp2;
                s1_mts1_ex  <= (exp1 == 0) ? {1'b0, mts1} : {1'b1, mts1};
                s1_mts2_ex  <= (exp2 == 0) ? {1'b0, mts2} : {1'b1, mts2};
                s1_sig <= final_sig;
            end
        end
    end

    // 2nd stage: mts multiplication, exp sum
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s2_temp <= 16'd0;
            s2_spc  <= 1'b0;
            s2_exp_sum <= 7'd0;
            s2_prod <= 22'd0;
            s2_sig  <= 1'b0;
        end 
        else begin
            s2_spc  <= s1_spc;
            s2_temp <= s1_temp;
            s2_sig  <= s1_sig;
            if (!s1_spc) begin
                s2_exp_sum <= s1_exp1_eff+s1_exp2_eff-15;
                s2_prod <= s1_mts1_ex * s1_mts2_ex;
            end 
            else begin
                s2_exp_sum <= 7'd0;
                s2_prod <= 22'd0;
            end
        end
    end

    // 3rd stage: normalize, round
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            result <= 16'd0;
        end 
        else if (s2_spc) begin
            result <= s2_temp;
        end 
        else begin
            adjusted_exp = s2_exp_sum;
            prod_norm = s2_prod;
            
            // normalization
            if (prod_norm[21]) begin
                prod_norm = prod_norm >> 1; // too big: right shift
                adjusted_exp = adjusted_exp+1;
            end 
            else begin
                shift = 0;
                while (!prod_norm[20] && shift < 21) begin // too small: left shift
                    prod_norm = prod_norm << 1;
                    shift = shift+1;
                    adjusted_exp = adjusted_exp-1;
                end
            end

            // result adjustment
            if (adjusted_exp > 0) begin // normal out
                final_exp = adjusted_exp[4:0];
                final_mts = prod_norm[20:10];
                // rounding
                guard = prod_norm[9];
                round = prod_norm[8];
                sticky = |prod_norm[7:0];
                if (guard && (round || sticky || final_mts[0])) begin
                    final_mts = final_mts+1;
                    if (final_mts == 11'b10000000000) begin
                        final_mts = final_mts >> 1;
                        final_exp = final_exp+1;
                    end
                end

                if (final_exp >= 5'd31)
                    result <= {s2_sig, 5'b11111, 10'd0}; // overflow -> inf
                else
                    result <= {s2_sig, final_exp, final_mts[9:0]};
            end 
            else begin // denormal out
                shift = (adjusted_exp < -21) ? 5'd31 : -adjusted_exp+1;
                prod_norm = prod_norm >> shift;
                final_mts = prod_norm[20:10];
                
                guard = prod_norm[9];
                round = prod_norm[8];
                sticky = |prod_norm[7:0];

                if (guard && (round || sticky || final_mts[0])) begin
                    final_mts = final_mts+1;
                    if (final_mts[10]) begin
                        final_mts = final_mts >> 1;
                        result <= {s2_sig, 5'd1, final_mts[9:0]}; // back to normal
                    end 
                    else begin
                        result <= {s2_sig, 5'd0, final_mts[9:0]};  
                    end
                end         
                else begin
                    result <= {s2_sig, 5'd0, final_mts[9:0]};
                end
                result <= {s2_sig, 5'd0, final_mts[9:0]};
            end
        end
    end

endmodule
