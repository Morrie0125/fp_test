`timescale 1ns / 1ps

module fp16_adder (
    input  wire clk,
    input  wire rst,
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg  [15:0] result
);

    reg        s1_valid;
    reg        s1_sig;
    reg [15:0] s1_sum_ex;
    reg [4:0]  s1_exp_al;
    reg        s1_spc; 
    reg [15:0] s1_temp;

    reg        sig1, sig2;
    reg [4:0]  exp1, exp2, exp1_eff, exp2_eff, exp_al;
    reg [9:0]  mts1, mts2;
    reg [15:0] mts1_ex, mts2_ex, mts1_al, mts2_al, sum_temp;

    reg [15:0] sum_ex;
    reg [4:0]  exp_al_s2;
    reg [10:0] final_mts;
    reg [4:0]  final_exp, raw_exp;
    reg [3:0]  shift, i;
    reg        found, guard, round, sticky;
    reg [15:0] sum_norm;
    reg [3:0]  extra_shift;
    reg        final_sig;
    reg        s2_skip;
    reg [15:0] s2_temp;

    // 1st stage: unpack, align, add/sub, special case check
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s1_valid    <= 1'b0;
            s1_sum_ex   <= 16'd0;
            s1_exp_al   <= 5'd0;
            s1_sig      <= 1'b0;
            s1_spc      <= 1'b0;
            s1_temp     <= 16'd0;
        end 
        else begin
            // unpacking
            sig1 = a[15];
            sig2 = b[15];
            exp1 = a[14:10];
            exp2 = b[14:10];
            mts1 = a[9:0];
            mts2 = b[9:0];

            // nan in, nan out
            if ((exp1 == 5'b11111 && mts1 != 10'd0) || (exp2 == 5'b11111 && mts2 != 10'd0)) begin
                s1_spc  <= 1'b1;
                s1_temp <= 16'h7FFF; 
            end 
            // inf + (-inf), nan out
            else if ((exp1 == 5'b11111 && exp2 == 5'b11111) && (sig1 != sig2)) begin
                s1_spc  <= 1'b1;
                s1_temp <= 16'h7FFF;
            end
            // inf in, inf out
            else if (exp1 == 5'b11111) begin
                s1_spc  <= 1'b1;
                s1_temp <= {sig1, 5'b11111, 10'd0}; 
            end 
            else if (exp2 == 5'b11111) begin
                s1_spc  <= 1'b1;
                s1_temp <= {sig2, 5'b11111, 10'd0}; 
            end 
            else begin
                s1_spc  <= 1'b0;
                s1_temp <= 16'd0;
                
                // mantissa extension: re-format to {carry bit, implicit x, 10-bit mantissa, 4-bit zeros for rounding} (2nd MSB: norm 1, denorm 0) 
                if (exp1 == 5'b0) begin
                    exp1_eff = 5'd1;
                    mts1_ex = {1'b0, 1'b0, mts1, 4'd0};
                end 
                else begin
                    exp1_eff = exp1;
                    mts1_ex = {1'b0, 1'b1, mts1, 4'd0};
                end
                if (exp2 == 5'b0) begin
                    exp2_eff = 5'd1;
                    mts2_ex = {1'b0, 1'b0, mts2, 4'd0};
                end 
                else begin
                    exp2_eff = exp2;
                    mts2_ex = {1'b0, 1'b1, mts2, 4'd0};
                end
                
                // exponents alignment
                if (exp1_eff > exp2_eff) begin
                    exp_al = exp1_eff;
                    mts1_al = mts1_ex;
                    mts2_al = mts2_ex >> (exp1_eff-exp2_eff);
                end 
                else begin
                    exp_al = exp2_eff;
                    mts1_al = mts1_ex >> (exp2_eff-exp1_eff);
                    mts2_al = mts2_ex;
                end
                
                // add (same sign), sub (diff signs)
                if (sig1 == sig2) begin // add
                    sum_temp = mts1_al+mts2_al;
                    s1_sig <= sig1;
                end 
                else begin // sub
                    if (mts1_al >= mts2_al) begin
                        sum_temp = mts1_al-mts2_al;
                        s1_sig <= sig1;
                    end 
                    else begin
                        sum_temp = mts2_al-mts1_al;
                        s1_sig <= sig2;
                    end
                end
                
                s1_sum_ex <= sum_temp;
                s1_exp_al <= exp_al;
            end
            s1_valid <= 1'b1;
        end
    end

    // 2nd stage: normalize, round
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            result <= 16'd0;
        end 
        else if (s1_valid) begin
            s2_skip = s1_spc;
            s2_temp = s1_temp;
            if (s2_skip) begin // special cases handled in 1st stage
                result <= s2_temp;
            end        
            else begin
                sum_ex     = s1_sum_ex;
                exp_al_s2  = s1_exp_al;
                final_sig  = s1_sig;
                if (sum_ex == 16'd0) begin
                    result <= 16'd0;
                end 
                else begin
                    // normalization
                    if (sum_ex[15]) begin // too big: overflow, need to shift back to [1,2)
                        sum_ex = sum_ex >> 1;
                        raw_exp = exp_al_s2+1;
                    end 
                    else begin // too small: need to shift left until the implicit one is at sum_ex[14]
                        found = 0;
                        shift = 0;
                        for (i=0; i<15; i=i+1) begin
                            if (!found && sum_ex[14-i]) begin
                                shift = i;
                                found = 1;
                            end
                        end
                        sum_ex = sum_ex << shift;
                        raw_exp = exp_al_s2-shift;
                    end
                    
                    if (raw_exp > 0) begin // normal out
                        final_exp = raw_exp;
                        guard  = sum_ex[3];
                        round  = sum_ex[2];
                        sticky = |sum_ex[1:0];
                        final_mts = sum_ex[14:4];
                        
                        // round to nearest even
                        if (guard && (round || sticky || final_mts[0])) begin
                            final_mts = final_mts+1;
                            //if (final_mts[10] == 1'b1) begin
                            if (final_mts == 11'b10000000000) begin
                                final_mts = final_mts >> 1;
                                final_exp = final_exp+1;
                            end
                        end

                        // exponent overflow then output infinity (7C00)
                        if (final_exp > 5'd30)
                            result <= {final_sig, 5'b11111, 10'b0};
                        else
                            result <= {final_sig, final_exp, final_mts[9:0]};
                    end 
                    else begin // denormal out: shift right extra to get real value                        
                        extra_shift = 1-raw_exp;
                        sum_norm = sum_ex >> extra_shift;
                        final_mts = sum_norm[14:4];
                        guard  = sum_norm[3];
                        round  = sum_norm[2];
                        sticky = |sum_norm[1:0];                       
                        if (guard && (round || sticky || final_mts[0])) begin
                            final_mts = final_mts+1;
                        end
                        
                        result <= {final_sig, 5'd0, final_mts[9:0]};
                    end
                end
            end
        end
    end

endmodule
