//============================================================================
//  Raiden II - video register file (CRTC scroll/enable + tile banks)
//
//  The registers the tilemap generator needs, captured off the CPU's register
//  window. This is NOT a complete SEI0160/seibu_crtc: only the writes Raiden II
//  actually makes are decoded, and CRTC reads are not implemented (the CPU
//  never performs one -- a 6M-cycle trace shows 70 CRTC writes and no reads).
//
//  Ground truth: MAME src/mame/seibu/seibu_crtc.cpp (register offsets) and
//  raiden2_v.cpp (tile_scroll_w, tilemap_enable_w, tile_bank_01_w,
//  cop_tile_bank_2_w), LGPL-2.1+.
//
//  CRTC window, 0x600 + offset:
//    0x1C  layer enable, ACTIVE LOW: bit0 BG, 1 MID, 2 FG, 3 TXT, 4 sprites
//    0x20  BG  scroll X     0x22  BG  scroll Y
//    0x24  MID scroll X     0x26  MID scroll Y
//    0x28  FG  scroll X     0x2A  FG  scroll Y
//
//  tile_scroll_w() indexes tilemaps by offset/2 in the order background,
//  midground, foreground -- which is why MID sits between BG and FG here and
//  not in the BG/MID/FG order the rest of the core uses.
//
//  Tile banks are assembled from two registers outside the CRTC window:
//    0x6CC (byte)  bg_bank  = {1'b0, d[0], 1'b0}      -> 0 or 2
//                  mid_bank = {1'b0, d[1], 1'b1}      -> 1 or 3
//    0x470 (word)  fg_bank  = {1'b1, d[15:14]}        -> 4..7, high byte only
//                  the register itself reads back (cop_tile_bank_2_r)
//    tx_bank is fixed at 0; Raiden II never changes it.
//
//  Reset values are MACHINE_RESET_MEMBER(raiden2_state,raiden2)'s
//  bank_reset(0,6,1,0): bg 0, fg 6, mid 1, tx 0. Note fg starts at 6 and only
//  becomes 4 once the game writes 0x470 -- the previous hardcoded 3'd4 was the
//  post-write steady state, not the reset state.
//============================================================================

module raiden2_video_regs (
    input  logic        clk,
    input  logic        reset,

    // Register window bus from raiden2_main
    input  logic [19:0] reg_addr,
    input  logic [15:0] reg_dout,
    input  logic  [1:0] reg_be,      // {upper lane, lower lane}
    input  logic        reg_we,      // one-clock write strobe
    input  logic        reg_rd,
    input  logic        crtc_cs,     // 0x600-0x63F
    input  logic        tilebank_cs, // 0x6CC
    input  logic        game_dx,     // 0 = Raiden II, 1 = Raiden DX
    output logic  [3:0] dx_prg_bank, // DX program bank, from cop_bank[15:12]
    input  logic        copbank_cs,  // 0x470-0x471

    // Read-back into the CPU
    output logic [15:0] reg_din,
    output logic        reg_din_oe,

    // To sei0200
    output logic [15:0] bg_scroll_x,
    output logic [15:0] bg_scroll_y,
    output logic [15:0] mid_scroll_x,
    output logic [15:0] mid_scroll_y,
    output logic [15:0] fg_scroll_x,
    output logic [15:0] fg_scroll_y,
    output logic  [2:0] bg_bank,
    output logic  [2:0] mid_bank,
    output logic  [2:0] fg_bank,
    output logic  [2:0] tx_bank,
    output logic  [4:0] layer_enable
);

    // MAME's COMBINE_DATA: merge only the lanes this cycle is driving.
    function logic [15:0] combine(input logic [15:0] old,
                                  input logic [15:0] nw,
                                  input logic  [1:0] be);
        combine = { be[1] ? nw[15:8] : old[15:8],
                    be[0] ? nw[7:0]  : old[7:0]  };
    endfunction

    logic [15:0] cop_bank;
    // DX takes its PROGRAM bank from the top nibble of this register:
    //   raidendx_cop_bank_2_w: m_mainbank->set_entry(m_cop_bank >> 12)
    // Raiden II ignores it and banks from 0x6CB instead.
    assign dx_prg_bank = cop_bank[15:12];
    logic [15:0] tilemap_enable;      // full width, like MAME's m_tilemap_enable
    // Raiden DX (and Sky Smasher) swap CRTC registers [0x10] and [0x20], which
    // MAME implements as read_alt/write_alt:
    //     read_word(bitswap<16>(offset, ...,5,3,4,2,1,0))
    // i.e. address bits 4 and 3 exchanged. Everything else about the register
    // file is identical, so this one swap is the whole difference.
    // Quartus 17.0 cannot index a function call result, so the merged
    // value is computed here rather than sliced inline below.
    // Note: combine(...)[5:4] compiles under Verilator but Quartus rejects
    // it outright -- do not put the slice back inline.
    wire  [15:0] cop_bank_next = combine(cop_bank, reg_dout, reg_be);

    wire   [5:0] crtc_raw = reg_addr[5:0];
    wire   [5:0] crtc_ofs = game_dx ? {crtc_raw[5], crtc_raw[3], crtc_raw[4], crtc_raw[2:0]}
                                    : crtc_raw;

    assign tx_bank      = 3'd0;
    assign layer_enable = tilemap_enable[4:0];

    always_ff @(posedge clk) begin
        if (reset) begin
            bg_scroll_x  <= 16'd0;  bg_scroll_y  <= 16'd0;
            mid_scroll_x <= 16'd0;  mid_scroll_y <= 16'd0;
            fg_scroll_x  <= 16'd0;  fg_scroll_y  <= 16'd0;
            tilemap_enable <= 16'd0;         // active low: everything on
            cop_bank     <= 16'd0;
            bg_bank      <= 3'd0;            // bank_reset(0,6,1,0)
            fg_bank      <= 3'd6;
            mid_bank     <= 3'd1;
        end else if (reg_we) begin
            if (crtc_cs) begin
                case (crtc_ofs)
                    6'h1C: tilemap_enable <= combine(tilemap_enable, reg_dout, reg_be);
                    6'h20: bg_scroll_x  <= combine(bg_scroll_x,  reg_dout, reg_be);
                    6'h22: bg_scroll_y  <= combine(bg_scroll_y,  reg_dout, reg_be);
                    6'h24: mid_scroll_x <= combine(mid_scroll_x, reg_dout, reg_be);
                    6'h26: mid_scroll_y <= combine(mid_scroll_y, reg_dout, reg_be);
                    6'h28: fg_scroll_x  <= combine(fg_scroll_x,  reg_dout, reg_be);
                    6'h2A: fg_scroll_y  <= combine(fg_scroll_y,  reg_dout, reg_be);
                    default: ;                // base-scroll regs 0x2C-0x3B unused
                endcase
            end

            // tile_bank_01_w is a u8 handler on the even byte.
            if (tilebank_cs && reg_be[0]) begin
                bg_bank  <= {1'b0, reg_dout[0], 1'b0};
                mid_bank <= {1'b0, reg_dout[1], 1'b1};
            end

            // 0x470. The register always merges, but the FG bank is derived
            // DIFFERENTLY per game -- this is not a cosmetic difference and
            // getting it wrong scrambles the foreground layer:
            //
            //   raiden2  cop_tile_bank_2_w:     4 | (data >> 14)
            //            from the WRITTEN data, bits [15:14], and only on
            //            ACCESSING_BITS_8_15.
            //   raidendx raidendx_cop_bank_2_w: 4 | ((cop_bank >> 4) & 3)
            //            from the MERGED register, bits [5:4], every write.
            //
            // DX additionally banks program ROM from cop_bank[15:12]; see
            // dx_prg_bank above.
            if (copbank_cs) begin
                cop_bank <= cop_bank_next;
                if (game_dx)
                    fg_bank <= {1'b1, cop_bank_next[5:4]};
                else if (reg_be[1])
                    fg_bank <= {1'b1, reg_dout[15:14]};
            end
        end
    end

    // cop_tile_bank_2_r
    always_comb begin
        reg_din    = 16'h0000;
        reg_din_oe = 1'b0;
        if (reg_rd && copbank_cs) begin
            reg_din    = cop_bank;
            reg_din_oe = 1'b1;
        end
    end

endmodule
