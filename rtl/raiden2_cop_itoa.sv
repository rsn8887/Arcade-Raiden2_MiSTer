//============================================================================
//  Raiden II - COP integer-to-BCD converter (the score display)
//
//  Ground truth: MAME src/mame/seibu/seibucop.cpp, raiden2cop_device::
//  bcd_update() / cop_itoa_*  (LGPL-2.1+).
//
//      0x420/1  itoa value, low  16 bits   (write triggers a conversion)
//      0x422/3  itoa value, high 16 bits   (write triggers a conversion)
//      0x424/5  itoa mode                  (blank-digit style only)
//      0x590-9  digits read back, two per word:
//                   word n = digits[2n] | (digits[2n+1] << 8)
//
//  MAME:
//      val = cop_itoa; digits = 9
//      for i in 0..8:
//          if (!val && i)  d[i] = (mode == 3) ? 0x30 : 0x20   // blank
//          else          { d[i] = 0x30 | (val % 10); val /= 10; }
//
//  Note MAME's comment about mode applies to cop_itoa_MODE, not to itoa: a
//  full attract run reads the digit results 120 times, so the score display
//  really does go through the COP on this title. Raiden II writes mode 2, so
//  blank digits are 0x20 (space), not 0x30 ('0').
//
//  Implementation: double dabble (shift-and-add-3) converts the whole 32-bit
//  value to 9 BCD digits in 32 clocks, rather than nine sequential divides by
//  ten. The leading-blank rule is then equivalent to "blank every digit above
//  the most significant non-zero one, except digit 0, which is always shown" --
//  which is what MAME's `!val && i` test computes as it divides down.
//============================================================================

module raiden2_cop_itoa (
    input  logic        clk,
    input  logic        reset,

    input  logic [10:0] reg_addr,
    input  logic [15:0] reg_data,
    input  logic        reg_we,

    input  logic  [2:0] rd_idx,       // (addr - 0x590) >> 1
    output logic [15:0] rd_data,

    output logic        busy
);

    logic [31:0] value;
    logic [15:0] mode;

    // 9 BCD digits, 4 bits each.
    logic [35:0] bcd;
    logic [31:0] shifter;
    logic  [5:0] step;

    wire [7:0] blank = (mode == 16'd3) ? 8'h30 : 8'h20;

    // Most significant non-zero digit; digit 0 is always shown.
    logic [3:0] msd;
    always_comb begin
        msd = 4'd0;
        for (int i = 1; i < 9; i++)
            if (bcd[i*4 +: 4] != 4'd0) msd = 4'(i);
    end

    function automatic [7:0] digit(input int i);
        digit = (4'(i) <= msd) ? {4'h3, bcd[i*4 +: 4]} : blank;
    endfunction

    always_comb begin
        case (rd_idx)
            3'd0: rd_data = {digit(1), digit(0)};
            3'd1: rd_data = {digit(3), digit(2)};
            3'd2: rd_data = {digit(5), digit(4)};
            3'd3: rd_data = {digit(7), digit(6)};
            3'd4: rd_data = {8'h00,    digit(8)};   // digits[9] is never written
            default: rd_data = 16'h0000;
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            value <= 32'd0; mode <= 16'd0; bcd <= 36'd0;
            shifter <= 32'd0; step <= 6'd0; busy <= 1'b0;
        // Register writes are accepted UNCONDITIONALLY and (re)start the
        // conversion. Gating them on !busy silently dropped the second of two
        // back-to-back writes -- which is exactly what the game does when it
        // sets 0x422 then 0x420 -- and MAME's bcd_update() is instantaneous, so
        // every write must take effect.
        end else if (reg_we && (reg_addr == 11'h420 || reg_addr == 11'h422
                                                    || reg_addr == 11'h424)) begin
            case (reg_addr)
                11'h420: begin value[15:0]  <= reg_data;
                               shifter <= {value[31:16], reg_data};
                               bcd <= 36'd0; step <= 6'd0; busy <= 1'b1; end
                11'h422: begin value[31:16] <= reg_data;
                               shifter <= {reg_data, value[15:0]};
                               bcd <= 36'd0; step <= 6'd0; busy <= 1'b1; end
                11'h424: mode <= reg_data;
                default: ;
            endcase
        end else if (busy) begin
            // Double dabble: add 3 to any digit >= 5, then shift the whole
            // {bcd, shifter} register left one bit. 32 steps for 32 input bits.
            logic [35:0] adj;
            for (int i = 0; i < 9; i++)
                adj[i*4 +: 4] = (bcd[i*4 +: 4] >= 4'd5) ? (bcd[i*4 +: 4] + 4'd3)
                                                        : bcd[i*4 +: 4];
            bcd     <= {adj[34:0], shifter[31]};
            shifter <= {shifter[30:0], 1'b0};
            step    <= step + 6'd1;
            if (step == 6'd31) busy <= 1'b0;
        end
    end
endmodule
