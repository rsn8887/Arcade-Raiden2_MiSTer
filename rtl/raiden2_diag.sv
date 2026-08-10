//============================================================================
//  Raiden II - self-test check accumulators
//
//  Watches signals that already exist in Raiden2.sv and turns them into the
//  pass/fail bus the self-test page displays. Everything here is observation
//  only: nothing in this module can change how the core behaves, so leaving it
//  in a release build costs logic and nothing else.
//
//  Most checks are liveness checks -- "did this ever happen" -- so a check that
//  has not fired yet is genuinely ambiguous between "not yet" and "never will".
//  They therefore start at WAIT and are declared FAIL once the core has been
//  running for SETTLE_FRAMES frames without the event, which turns the page
//  into an actual pass/fail list instead of a column of WAITs.
//
//  Check order must match tools/make_selftest_page.py's CHECKS list.
//============================================================================

module raiden2_diag #(
    parameter int SETTLE_FRAMES = 8,
    // CPU BOOT gets its own, much longer deadline. 8 frames (0.14 s) is fine
    // for events that happen every frame, but the boot-entry window is touched
    // ONCE, early, and only after the game has got going: a MAME read tap
    // (tools/, 2026-08-10) puts Raiden DX's first access to 0x98000-0x98010 at
    // frame 836, i.e. ~100x past the 8-frame deadline. The check therefore
    // reported FAIL on every DX run no matter how healthy the core -- a test
    // bug that cost a board investigation. 1200 frames (~21 s) clears DX's 836
    // with margin. The counter below is 16-bit for this reason; an 8-bit one
    // silently saturates at 255 and reintroduces the same false failure.
    parameter int BOOT_SETTLE_FRAMES = 1200
) (
    input  logic        clk,
    input  logic        reset,          // system reset
    input  logic        core_reset,     // core held off (download / BIST / user reset)

    // 0 PLL / 1 ROM LOAD / 2 SDRAM
    input  logic        pll_locked,
    input  logic        dl_active,
    input  logic        dl_done,
    input  logic        bist_busy,
    input  logic        bist_done,
    input  logic        bist_pass,

    // 3 CPU FETCH / 4 CPU BOOT / 5 VBLANK IRQ
    input  logic        cpu_fetch_done, // pulse: a program word arrived from SDRAM
    input  logic [19:0] dbg_addr,
    input  logic        dbg_mem_rd,
    input  logic        dbg_intack,

    // 6,7,8 COP DMA
    input  logic [19:0] reg_addr,
    input  logic [15:0] reg_dout,
    input  logic        reg_we,
    input  logic        dma_unknown,

    // 9,10 COP destination buffers, seen through the video read ports
    input  logic [15:0] cram_data,
    input  logic [15:0] map_data,

    // 11 GFX / 12 SPRITE / 13 PIXELS
    input  logic        gfx_valid,
    input  logic        sprbuf_cs,
    input  logic [10:0] px,
    input  logic        video_active,

    input  logic        vblank_rise,

    // 14 SPRITE DECRYPT -- the loader's running checksum of the DECRYPTED
    // sprite region, compared against the value tools/r2crypt.py produces for
    // the same ROM set. This is the only check that proves the hardware
    // decryptor agrees with the oracle on a real board rather than in sim.
    input  logic        crypt_done,
    input  logic        crypt_pass,

    // 15 SPRITE FETCH CH2 / 16 SPRITE PIXELS. Deliberately separate: the first
    // says sprite ROM words are coming back over ch2 at all, the second says
    // the renderer turned them into visible pixels. Splitting them means a
    // blank screen points at one stage rather than the whole path.
    input  logic        spr_rom_ack,
    input  logic        spr_pixel,

    // 17 SOUND Z80 RUNS / 18 YM2151 WRITES. The first means the sound CPU is
    // fetching from changing addresses -- i.e. actually executing rather than
    // reading a stuck bus. The second means it got far enough to program the
    // FM chip. Coins are read by this CPU, so both failing explains a game
    // that will not take a credit.
    input  logic        z80_running,
    input  logic        ym_write,

    // 19 COP CMDS KNOWN. Separate from COP MODES KNOWN, which covers the DMA
    // engine: this one fires when the command engine is handed a trigger it
    // does not implement.
    input  logic        cmd_unknown,

    // 20 OKI ROM FETCH / 21 AUDIO NONZERO. These split "no sound" into its two
    // possible halves: whether the ADPCM channels are getting sample data over
    // ch4 at all, and whether anything ever reaches the mixer output. With
    // both passing, silence is downstream of the core entirely.
    input  logic        oki_ack,
    input  logic        audio_nz,

    output logic [43:0] chk_state
);

    localparam logic [1:0] ST_WAIT = 2'd0;
    localparam logic [1:0] ST_BUSY = 2'd1;
    localparam logic [1:0] ST_PASS = 2'd2;
    localparam logic [1:0] ST_FAIL = 2'd3;

    //------------------------------------------------------------------
    // Settle timer: frames since the core was last released.
    //------------------------------------------------------------------
    logic [15:0] frames;
    wire         settled      = (frames >= SETTLE_FRAMES[15:0]);
    wire         boot_settled = (frames >= BOOT_SETTLE_FRAMES[15:0]);

    always_ff @(posedge clk) begin
        if (reset || core_reset) frames <= 16'd0;
        else if (vblank_rise && !boot_settled) frames <= frames + 16'd1;
    end

    //------------------------------------------------------------------
    // Liveness flags
    //------------------------------------------------------------------
    logic [7:0] fetch_count;
    logic       hit_boot, hit_irq;
    logic       hit_dma14, hit_dma15, hit_unknown;
    logic       hit_cram, hit_map;
    logic [8:0] gfx_count;
    logic       hit_spr, hit_px;
    logic [8:0] dma_mode;

    // 0x6FC runs the channel selected by the last write to 0x47E; both sit in
    // the 0x400-0x7FF window, so addr[10:0] identifies them exactly.
    wire [10:0] rwin      = reg_addr[10:0];
    wire        wr_mode   = reg_we && (rwin == 11'h47E);
    wire        wr_trig   = reg_we && (rwin == 11'h6FC);

    // Matches the sim harness's boot-entry probe.
    wire        at_boot   = dbg_mem_rd && (dbg_addr >= 20'h98000) && (dbg_addr <= 20'h98010);

    always_ff @(posedge clk) begin
        if (reset || core_reset) begin
            fetch_count <= 8'd0;
            hit_boot    <= 1'b0;
            hit_irq     <= 1'b0;
            hit_dma14   <= 1'b0;
            hit_dma15   <= 1'b0;
            hit_unknown <= 1'b0;
            hit_cram    <= 1'b0;
            hit_map     <= 1'b0;
            gfx_count   <= 9'd0;
            hit_spr     <= 1'b0;
            hit_px      <= 1'b0;
            dma_mode    <= 9'd0;
        end else begin
            if (cpu_fetch_done && !(&fetch_count)) fetch_count <= fetch_count + 8'd1;
            if (at_boot)      hit_boot <= 1'b1;
            if (dbg_intack)   hit_irq  <= 1'b1;

            if (wr_mode) dma_mode <= reg_dout[8:0];
            if (wr_trig) begin
                if (dma_mode == 9'h014) hit_dma14 <= 1'b1;
                if (dma_mode == 9'h015) hit_dma15 <= 1'b1;
            end
            if (dma_unknown) hit_unknown <= 1'b1;

            if (|cram_data) hit_cram <= 1'b1;
            if (|map_data)  hit_map  <= 1'b1;

            if (gfx_valid && !(&gfx_count)) gfx_count <= gfx_count + 9'd1;
            if (reg_we && sprbuf_cs) hit_spr <= 1'b1;
            if (video_active && |px) hit_px <= 1'b1;
        end
    end

    //------------------------------------------------------------------
    // Result bus
    //------------------------------------------------------------------
    function automatic [1:0] verdict(input logic hit);
        verdict = hit ? ST_PASS : (settled ? ST_FAIL : ST_WAIT);
    endfunction

    // Same, on the long deadline -- for one-shot events that only occur once
    // the game is well under way.
    function automatic [1:0] verdict_slow(input logic hit);
        verdict_slow = hit ? ST_PASS : (boot_settled ? ST_FAIL : ST_WAIT);
    endfunction

    logic [1:0] st_pll, st_rom, st_sdram;

    always_comb begin
        st_pll = pll_locked ? ST_PASS : ST_FAIL;

        // The settled fallback matters: if the core is started without a ROM
        // download at all, these would otherwise sit on WAIT forever rather
        // than reporting that nothing was ever loaded.
        if      (dl_active) st_rom = ST_BUSY;
        else if (dl_done)   st_rom = ST_PASS;
        else if (settled)   st_rom = ST_FAIL;
        else                st_rom = ST_WAIT;

        if      (bist_busy) st_sdram = ST_BUSY;
        else if (bist_done) st_sdram = bist_pass ? ST_PASS : ST_FAIL;
        else if (settled)   st_sdram = ST_FAIL;
        else                st_sdram = ST_WAIT;
    end

    // The COP has to have run at least once before "no unknown modes" means
    // anything, otherwise it would read PASS on a core whose COP never started.
    wire cop_ran = hit_dma14 | hit_dma15;

    logic [1:0] st_crypt;
    always_comb begin
        if      (crypt_done) st_crypt = crypt_pass ? ST_PASS : ST_FAIL;
        else if (dl_active)  st_crypt = ST_BUSY;
        else                 st_crypt = ST_WAIT;
    end

    logic [8:0] spr_fetch_count;
    logic       hit_spr_px;
    always_ff @(posedge clk) begin
        if (core_reset) begin
            spr_fetch_count <= 9'd0;
            hit_spr_px      <= 1'b0;
        end else begin
            if (spr_rom_ack && !spr_fetch_count[8])
                spr_fetch_count <= spr_fetch_count + 9'd1;
            if (spr_pixel) hit_spr_px <= 1'b1;
        end
    end

    logic hit_ym_w;
    always_ff @(posedge clk) begin
        if (core_reset)   hit_ym_w <= 1'b0;
        else if (ym_write) hit_ym_w <= 1'b1;
    end

    logic hit_cmd_unk;
    always_ff @(posedge clk) begin
        if (core_reset)       hit_cmd_unk <= 1'b0;
        else if (cmd_unknown) hit_cmd_unk <= 1'b1;
    end

    logic [7:0] oki_count;
    logic       hit_audio;
    always_ff @(posedge clk) begin
        if (core_reset) begin
            oki_count <= 8'd0;
            hit_audio <= 1'b0;
        end else begin
            if (oki_ack && !oki_count[7]) oki_count <= oki_count + 8'd1;
            if (audio_nz) hit_audio <= 1'b1;
        end
    end

    assign chk_state = {
        verdict(hit_audio),                     // 21 AUDIO NONZERO
        verdict(oki_count >= 8'd32),            // 20 OKI ROM FETCH
        verdict(cop_ran & ~hit_cmd_unk),        // 19 COP CMDS KNOWN
        verdict(hit_ym_w),                      // 18 YM2151 WRITES
        verdict(z80_running),                   // 17 SOUND Z80 RUNS
        verdict(hit_spr_px),                    // 16 SPRITE PIXELS
        verdict(spr_fetch_count >= 9'd256),     // 15 SPRITE FETCH CH2
        st_crypt,                               // 14 SPRITE DECRYPT
        verdict(hit_px),                        // 13 PIXELS OUT
        verdict(hit_spr),                       // 12 SPRITE LATCH
        verdict(gfx_count >= 9'd256),           // 11 GFX ROM FETCH
        verdict(hit_map),                       // 10 TILEMAP FILLED
        verdict(hit_cram),                      //  9 CRAM FILLED
        verdict(cop_ran & ~hit_unknown),        //  8 COP MODES KNOWN
        verdict(hit_dma15),                     //  7 COP DMA PALETTE
        verdict(hit_dma14),                     //  6 COP DMA TILEMAP
        verdict(hit_irq),                       //  5 VBLANK IRQ
        verdict_slow(hit_boot),                 //  4 CPU BOOT
        verdict(fetch_count >= 8'd16),          //  3 CPU FETCH
        st_sdram,                               //  2 SDRAM VERIFY
        st_rom,                                 //  1 ROM LOAD
        st_pll                                  //  0 PLL LOCK
    };

endmodule
