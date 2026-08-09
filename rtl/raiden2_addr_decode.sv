//============================================================================
//  Raiden II - main CPU (V30) address decode
//
//  Ground truth: MAME src/mame/seibu/raiden2.cpp, raiden2_mem() / raiden2_cop_mem()
//  (LGPL-2.1+, Olivier Galibert, David Haywood, Angelo Salese et al.)
//
//  Purely combinational. The bank register itself lives in the parent so this
//  stays testable in isolation.
//
//  CPU physical map:
//    00000-003FF  RAM (interrupt vectors + scratch)
//    00400-007FF  register window  <- the only hole in the low 128K
//    00800-0BFFF  work RAM
//    0C000-0CFFF  sprite RAM (buffered into SEI252 by a write to 0x68E)
//    0D000-0D7FF  BG tilemap    0D800-0DFFF  FG    0E000-0E7FF  MID
//    0E800-0F7FF  text tilemap
//    0F800-0FFFF  stack RAM
//    10000-1EFFF  work RAM
//    1F000-1FFFF  palette RAM
//    20000-3FFFF  banked program ROM (2 x 128K)
//    40000-FFFFF  fixed program ROM
//
//  Note the CPU never touches real VRAM or CRAM: 0xC000-0x1FFFF are ordinary
//  RAM shadow copies that the COP later DMAs into the video chips' private
//  buffers. So everything below 0x20000 except the register window is just RAM.
//============================================================================

module raiden2_addr_decode (
    input  logic [19:0] addr,        // CPU physical address
    input  logic  [3:0] prg_bank,    // program bank entry
    input  logic        game_dx,     // 0 = Raiden II, 1 = Raiden DX

    // Bulk regions
    output logic        ram_cs,      // 0x00000-0x1FFFF minus the register window
    output logic        rom_cs,      // 0x20000-0xFFFFF
    // 21 bits, not 20: Raiden DX has a 2 MB program ROM and banks the window
    // from +0x100000, so the translated offset runs past the 1 MB the CPU can
    // address directly.
    output logic [20:0] rom_addr,    // ROM offset after bank translation

    // --- register window 0x400-0x7FF -------------------------------------
    output logic        reg_cs,      // whole window, for "unmapped register" logging

    output logic        cop_cs,      // 0x400-0x5FF: COP params, DMA setup, regs, cmd, results
                                     //   (minus 0x470, which is carved out below)
    output logic        copbank_cs,  // 0x470-0x471: COP bank reg; r/w, drives the FG tile bank
    output logic        crtc_cs,     // 0x600-0x63F: layer enable, scrolls  [DX: swapped layout]
    output logic        sprite_cs,   // 0x640-0x6BF: SEI252, incl. 0x6A0-0x6BF key upload
    output logic        sprbuf_cs,   // 0x68E: latch sprite RAM into SEI252's buffer
    output logic        sprprot_cs,  // 0x6C0-0x6DF: COP sprite-prot / list builder
    output logic        prgbank_cs,  // 0x6CA-0x6CB: program ROM bank (bit 7, byte write to 0x6CB)
    output logic        tilebank_cs, // 0x6CC only (even byte): BG/MID tile bank
    output logic        copdma_cs,   // 0x6FC: COP DMA trigger
    output logic        copsort_cs,  // 0x6FE: sort-DMA trigger

    output logic        sound_cs,    // 0x700-0x71F: SIE150 latch window (low bytes only)
    output logic        dsw_cs,      // 0x740-0x741
    output logic        p1p2_cs,     // 0x744-0x745
    output logic        system_cs,   // 0x74C-0x74D
    output logic        sprprot_rd_cs// 0x762-0x763: sprite-prot destination readback
);

    // 0x400-0x7FF is the register window: bits [19:10] == 1.
    wire in_reg_window = (addr[19:10] == 10'd1);
    wire [9:0] a = addr[9:0];

    assign reg_cs = in_reg_window;

    assign ram_cs = (addr < 20'h20000) && !in_reg_window;
    assign rom_cs = (addr >= 20'h20000);

    // Raiden II: 0x20000-0x3FFFF is a 128K window over TWO banks, and
    // 0x40000+ is fixed, mapping 1:1 onto the ROM image.
    //
    // Raiden DX rearranges this completely (MAME raidendx_mem):
    //     map(0x20000, 0x2ffff).bankr(m_mainbank);      64K window
    //     map(0x30000, 0xfffff).rom().region(..0x30000) fixed from 0x30000
    // with configure_entries(0, 0x10, base + 0x100000, 0x10000) -- SIXTEEN
    // 64K banks living in the SECOND megabyte of a 2 MB ROM. The bank number
    // arrives in the top nibble of the word written to 0x470, not from 0x6CB.
    always_comb begin
        if (game_dx) begin
            if (addr < 20'h30000) rom_addr = 21'h100000 + {5'd0, prg_bank, addr[15:0]};
            else                  rom_addr = {1'b0, addr};
        end else begin
            if (addr < 20'h40000) rom_addr = {3'b000, prg_bank[0], addr[16:0]};
            else                  rom_addr = {1'b0, addr};
        end
    end

    // --- register window sub-decode --------------------------------------
    // Decoded most-specific-first, matching MAME's later-map()-wins ordering:
    // 0x68E sits inside the SEI252 range, and 0x6CA/0x6CB/0x6CC sit inside the
    // sprite-prot range.
    always_comb begin
        cop_cs        = 1'b0;
        copbank_cs    = 1'b0;
        crtc_cs       = 1'b0;
        sprite_cs     = 1'b0;
        sprbuf_cs     = 1'b0;
        sprprot_cs    = 1'b0;
        prgbank_cs    = 1'b0;
        tilebank_cs   = 1'b0;
        copdma_cs     = 1'b0;
        copsort_cs    = 1'b0;
        sound_cs      = 1'b0;
        dsw_cs        = 1'b0;
        p1p2_cs       = 1'b0;
        system_cs     = 1'b0;
        sprprot_rd_cs = 1'b0;

        // Written as a priority if/else rather than `case (...) inside`:
        // Quartus 17.0 does not accept the SystemVerilog-2012 set-membership
        // case, even though Verilator does. The ordering is the same as
        // MAME's later-map()-wins: the specific addresses must be tested
        // before the ranges that contain them (0x68E sits inside the SEI252
        // range; 0x6CA/0x6CB/0x6CC sit inside the sprite-prot range).
        if (in_reg_window) begin
            if      (a == 10'h28E || a == 10'h28F) sprbuf_cs     = 1'b1;  // 0x68E
            else if (a == 10'h2CA || a == 10'h2CB) prgbank_cs    = 1'b1;  // 0x6CA-0x6CB
            // MAME maps 0x6CC as a single BYTE (tile_bank_01_w takes a u8), so
            // only the even address decodes -- a byte write to 0x6CD is not it.
            else if (a == 10'h2CC)                 tilebank_cs   = 1'b1;  // 0x6CC
            else if (a == 10'h2FC || a == 10'h2FD) copdma_cs     = 1'b1;  // 0x6FC
            else if (a == 10'h2FE || a == 10'h2FF) copsort_cs    = 1'b1;  // 0x6FE
            else if (a == 10'h362 || a == 10'h363) sprprot_rd_cs = 1'b1;  // 0x762
            else if (a == 10'h070 || a == 10'h071) copbank_cs    = 1'b1;  // 0x470-0x471
            else if (a <= 10'h1FF)                 cop_cs        = 1'b1;  // 0x400-0x5FF
            else if (a <= 10'h23F)                 crtc_cs       = 1'b1;  // 0x600-0x63F
            else if (a <= 10'h2BF)                 sprite_cs     = 1'b1;  // 0x640-0x6BF
            else if (a <= 10'h2DF)                 sprprot_cs    = 1'b1;  // 0x6C0-0x6DF
            else if (a >= 10'h300 && a <= 10'h31F) sound_cs      = 1'b1;  // 0x700-0x71F
            else if (a == 10'h340 || a == 10'h341) dsw_cs        = 1'b1;  // 0x740-0x741
            else if (a == 10'h344 || a == 10'h345) p1p2_cs       = 1'b1;  // 0x744-0x745
            else if (a == 10'h34C || a == 10'h34D) system_cs     = 1'b1;  // 0x74C-0x74D
            // anything else in the window is unmapped
        end
    end

endmodule
