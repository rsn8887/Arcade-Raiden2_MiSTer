//==========================================================================
//  SEI360 mixer -- layer priority and the 50% alpha table
//
//  GENERATED blend table (from MAME raiden2.cpp raiden_blended_colors[]);
//  the logic below is hand-written. Regenerate with tools/mix_model.py,
//  which is also the oracle sim/tb_sei360.cpp diffs against.
//
//  screen_update() draws back to front:
//     spr0, BG, spr1, MID, spr2, FG, spr3, TXT
//  so front-to-back is TXT > spr3 > FG > spr2 > MID > spr1 > BG > spr0 >
//  backdrop. Later draws overwrite earlier ones.
//
//  Blended entries are drawn at 50% over what is behind them, so this
//  resolves the top TWO opaque layers, not just the top one.
//
//  Purely combinational and independent of every other block -- it sees
//  only line-buffer values, which is what makes it testable on its own.
//==========================================================================

module raiden2_sei360 (
    // {opaque, palette index[10:0]}
    input  logic [11:0] lb_bg,
    input  logic [11:0] lb_mid,
    input  logic [11:0] lb_fg,
    input  logic [11:0] lb_txt,
    // {opaque, pri[1:0], colour[5:0], pen[3:0]}
    input  logic [12:0] lb_spr,

    output logic        opaque,
    output logic [10:0] top_idx,
    output logic        blend,
    output logic [10:0] under_idx
);

    // A sprite pixel carries one priority, so at most one of the four
    // sprite slots is live at any x.
    wire [10:0] spr_idx = {1'b0, lb_spr[9:0]};      // colour*16 + pen
    wire  [1:0] spr_pri = lb_spr[11:10];
    wire        spr_op  = lb_spr[12];

    wire  [7:0] hit;
    wire [10:0] val [0:7];

    assign hit[7] = lb_txt[11];                 assign val[7] = lb_txt[10:0];
    assign hit[6] = spr_op & (spr_pri == 2'd3); assign val[6] = spr_idx;
    assign hit[5] = lb_fg[11];                  assign val[5] = lb_fg[10:0];
    assign hit[4] = spr_op & (spr_pri == 2'd2); assign val[4] = spr_idx;
    assign hit[3] = lb_mid[11];                 assign val[3] = lb_mid[10:0];
    assign hit[2] = spr_op & (spr_pri == 2'd1); assign val[2] = spr_idx;
    assign hit[1] = lb_bg[11];                  assign val[1] = lb_bg[10:0];
    assign hit[0] = spr_op & (spr_pri == 2'd0); assign val[0] = spr_idx;

    // Topmost and second-topmost, scanning front to back.
    integer i;
    reg found_top, found_under;
    always_comb begin
        opaque      = 1'b0;
        top_idx     = 11'd0;
        under_idx   = 11'd0;    // nothing behind -> backdrop, palette 0
        found_top   = 1'b0;
        found_under = 1'b0;
        for (i = 7; i >= 0; i = i - 1) begin
            if (hit[i]) begin
                if (!found_top) begin
                    top_idx   = val[i];
                    found_top = 1'b1;
                end else if (!found_under) begin
                    under_idx   = val[i];
                    found_under = 1'b1;
                end
            end
        end
        opaque = found_top;
    end

    // 50% alpha palette entries.
    always_comb begin
        case (top_idx)
        11'h380, 11'h3C0, 11'h3C1, 11'h3C2, 11'h3C3, 11'h3C4, 11'h3C5, 11'h3C6,
        11'h3C7, 11'h3C8, 11'h3C9, 11'h3CA, 11'h3CB, 11'h3CC, 11'h3CD, 11'h3CE,
        11'h3D0, 11'h3D1, 11'h3D2, 11'h3D3, 11'h3D4, 11'h3D5, 11'h3D6, 11'h3D7,
        11'h3D8, 11'h3D9, 11'h3DA, 11'h3DB, 11'h3DC, 11'h3DD, 11'h3DE, 11'h3F0,
        11'h3F1, 11'h3F2, 11'h3F3, 11'h3F4, 11'h3F5, 11'h3F6, 11'h3F7, 11'h3F8,
        11'h3F9, 11'h3FA, 11'h3FB, 11'h3FC, 11'h3FD, 11'h3FE, 11'h4F8, 11'h4F9,
        11'h4FA, 11'h4FB, 11'h4FC, 11'h4FD, 11'h4FE, 11'h5C8, 11'h5C9, 11'h5CA,
        11'h5CB, 11'h5CC, 11'h5CD, 11'h5CE, 11'h5DE, 11'h5E8, 11'h5E9, 11'h5EA,
        11'h5EB, 11'h5EC, 11'h5ED, 11'h5EE, 11'h5F8, 11'h5F9, 11'h5FA, 11'h5FB,
        11'h5FC, 11'h5FD, 11'h5FE, 11'h6C8, 11'h6C9, 11'h6CA, 11'h6CB, 11'h6CC,
        11'h6CD, 11'h6CE, 11'h6D8, 11'h6D9, 11'h6DA, 11'h6DB, 11'h6DC, 11'h6DD,
        11'h6DE, 11'h6E8, 11'h6E9, 11'h6EA, 11'h6EB, 11'h6EC, 11'h6ED, 11'h6EE,
        11'h6F8, 11'h6F9, 11'h6FA, 11'h6FB, 11'h6FC, 11'h6FD, 11'h6FE, 11'h70D,
        11'h70E, 11'h71C, 11'h71D, 11'h71E, 11'h72D, 11'h72E, 11'h73D, 11'h73E,
        11'h74D, 11'h74E, 11'h75C, 11'h76C, 11'h76D, 11'h76E, 11'h77D, 11'h77E,
        11'h7C8, 11'h7C9, 11'h7CA, 11'h7CB, 11'h7CC, 11'h7CD, 11'h7CE:
                blend = 1'b1;
            default: blend = 1'b0;
        endcase
    end

endmodule
