//============================================================================
//  Raiden II - Seibu COP (SEI1000) DMA engine
//
//  The CPU never writes real VRAM or CRAM. It keeps shadow copies in work RAM
//  and the COP DMAs them into the video chips' private buffers once a frame.
//  Nothing displays until this block works, which is why it comes before any
//  video RTL.
//
//  Ground truth: MAME src/mame/seibu/seibucop.cpp + seibucop_dma.ipp
//  (LGPL-2.1+, Olivier Galibert, Angelo Salese, David Haywood, Tomasz Slanina).
//
//  Register model: 0x47E selects a channel, and 0x478/0x47A/0x47C write that
//  channel's src/size/dst slot. A write to 0x6FC runs the selected channel.
//
//  Raiden II only ever uses two channels -- verified by capturing every 0x6FC
//  trigger from the running V30 over 68 frames:
//
//    mode 0x14  tilemap RAM -> video private buffer   src 0x0CFC0 size 0x27B
//    mode 0x15  palette RAM -> CRAM                   src 0x1F000 size 0x0FF
//
//  Parameters are identical every frame. The other modes MAME implements
//  (fill, palette fade 0x80-0x87, word copy 0x09/0x0E, z-sort) are used by
//  other Seibu games, not by this one; they are deliberately not implemented,
//  and an unrecognised mode raises dma_unknown rather than silently doing
//  nothing.
//
//  Two quirks carried over from MAME, both of which our capture reproduces:
//
//  1. Raiden II programs src = 0x0CFC0 for the tilemap channel, which is 0x40
//     bytes short of the 0xD000 tilemap base and actually lands in sprite RAM.
//     MAME rewrites it to 0xD000. Note that reading the dst register as SIGNED
//     (0xFFFE = -2) makes MAME's general size formula
//     ((size<<5) - (dst<<6) + 0x20) evaluate to exactly 0x2800, which supports
//     the "it also sets up odd size / dest regs, they probably counteract
//     this" guess in seibucop_dma.ipp. Until that is confirmed on hardware we
//     follow MAME: fix up the address, use the fixed length.
//
//  2. Transfer lengths are fixed rather than taken from the size register:
//     0x2800 bytes of tilemap, 0x1000 bytes of palette.
//
//  Timing is NOT hardware-accurate: real COP latency and any cycle-stealing
//  behaviour have never been measured. MAME performs the whole transfer
//  instantaneously mid-instruction; this block instead holds the CPU off the
//  bus for the duration, which is the conservative choice. ~7200 words at
//  64 MHz is about 112 us, comfortably inside an 18 ms frame.
//============================================================================

module raiden2_cop_dma (
    input  logic        clk,
    input  logic        reset,

    // Register window writes from the CPU. reg_addr is addr[10:0] and reg_we is
    // a one-clock strobe. Only the COP's own registers are matched here; the
    // two trigger addresses come in pre-decoded, because they are also decoded
    // by raiden2_addr_decode and having two decoders disagree about the slice
    // width is exactly how the 0x68E latch ended up unreachable.
    input  logic [10:0] reg_addr,
    input  logic [15:0] reg_data,
    input  logic        reg_we,
    input  logic        dma_trig,     // write to 0x6FC
    input  logic        spr_trig,     // write to 0x68E

    // Work RAM master port. Read latency must match the RAM (2 clocks).
    // The fill mode also WRITES work RAM, which the tilemap/palette channels
    // never do -- they read work RAM and write the video buffers.
    output logic [15:0] ram_addr,     // word address
    output logic        ram_req,
    input  logic [15:0] ram_data,
    output logic [15:0] ram_wdata,
    output logic        ram_we,

    // Tilemap private buffer (0x2800 bytes = 0x1400 words)
    output logic [12:0] vram_addr,
    output logic [15:0] vram_data,
    output logic        vram_we,

    // Palette / CRAM (0x1000 bytes = 0x800 words)
    output logic [10:0] cram_addr,
    output logic [15:0] cram_data,
    output logic        cram_we,

    // SEI252's private sprite buffer (0x1000 bytes = 0x800 words).
    // NOTE: on real hardware this transfer belongs to SEI252, not the COP --
    // a write to 0x68E latches sprite RAM into the chip, which is what gives
    // sprites their one-frame delay. It is driven from here only because this
    // is the block that already masters work RAM; keeping a second bus master
    // just for it would buy nothing.
    output logic [10:0] sprram_addr,
    output logic [15:0] sprram_data,
    output logic        sprram_we,

    output logic        busy,         // hold the CPU off the bus while high
    output logic        dma_unknown,  // pulses on a trigger we don't implement
    // The FIRST unimplemented mode seen, latched. "COP MODES KNOWN failed" on
    // its own is not actionable -- this says which mode to go and implement.
    output logic  [8:0] unknown_mode,
    output logic        unknown_valid
);

    localparam logic [8:0] MODE_TILEMAP = 9'h014;
    localparam logic [8:0] MODE_PALETTE = 9'h015;

    // A fourth pseudo-mode for the SEI252 sprite latch, which has no COP mode
    // number of its own -- it is triggered by the 0x68E write, not by 0x6FC.
    localparam logic [8:0] MODE_SPRITE  = 9'h1FF;

    // 0x118-0x11F all map to MAME's dma_fill(). Raiden II uses 0x118.
    //
    // Found by the on-screen self test on real hardware -- COP MODES KNOWN
    // failed because this mode raised dma_unknown. A 20M-cycle sim never
    // reaches it; a 150M-cycle run triggers it 42 times.
    //
    // Every observed trigger fills from somewhere inside sprite RAM up to
    // exactly 0x0D000 with zeros, so this is the SPRITE LIST TERMINATOR: the
    // game builds a list upward from 0x0C000 and blanks the tail. The start
    // offset therefore states the list length (0x0C040 = 8 entries, 0x0C0C0 =
    // 24, 0x0C100 = 32). Without it the stale tail of last frame's list is
    // never cleared.
    wire is_fill_mode = (dma_mode[8:3] == 6'b100011);   // 0x118-0x11F

    // Modes MAME actually implements. Its dispatch is a switch with NO default
    // and NO case 0, so every other mode number -- including 0, which is simply
    // dma_mode at its reset value -- falls through and does nothing at all.
    //
    // That distinction matters. dma_unknown must mean "the game asked for a
    // transfer with real behaviour that this core has not ported", not "a mode
    // number I do not recognise". Flagging the latter produced a false COP
    // MODES KNOWN failure on hardware reporting mode 0x000: the game triggers
    // 0x6FC without having selected a channel, MAME ignores it, and so should
    // we. A 150M-cycle sim (~2.3 s of game time) never reaches that point.
    //
    // Of these, we implement 0x14, 0x15 and 0x118-0x11F; the rest are used by
    // other Seibu games and are the ones genuinely worth reporting.
    wire mame_has_behaviour =
           (dma_mode == 9'h009)                  // word copy
        || (dma_mode == 9'h00e)                  // word copy (Godzilla, Cup Soccer)
        || (dma_mode[8:3] == 6'b010000)          // 0x080-0x087 palette fade
        || (dma_mode == 9'h116);                 // fill variant (Godzilla)

    // Length the game ACTUALLY asked for, in words: MAME's size convention is
    // (size+1) * 32 bytes = (size+1) << 4 words -- the same formula the fill
    // path below already uses. Clamped to the palette size so a bogus size can
    // never run off the end of CRAM.
    //
    // This channel used to copy a HARDCODED PALETTE_WORDS every time, on the
    // strength of a header claim that the parameters are "identical every
    // frame ... verified over 68 frames". That capture was 68 frames of
    // ATTRACT. Measured against MAME through gameplay (tools/oracle_dmaparm.lua)
    // the game issues 26 distinct parameter sets, walking src 0x301->0x30B+
    // while size SHRINKS 0x7D->0x69 -- a fade repainting an ever-smaller tail
    // of the palette. Copying a fixed 2048 words from the moving start
    // overran by 32 words at the start of a fade and 352 by the end, writing
    // stale work RAM over palette entries the game never touched. Every fade
    // compounded the last, which is why the colours rotted the longer it ran
    // and why the FADE was what triggered it. Proven by a CRAM checksum: the
    // same scene rendered clean and corrupted hashes differently. HANDOFF #72.
    wire [13:0] pal_req_words = ({5'd0, size_q[8:0]} + 14'd1) << 4;

    localparam int TILEMAP_WORDS = 'h1400;   // 0x2800 bytes
    localparam int PALETTE_WORDS = 'h0800;   // 0x1000 bytes
    localparam int SPRITE_WORDS  = 'h0800;   // 0x1000 bytes at work RAM 0xC000

    // ------------------------------------------------------------------
    // Channel register files. Indexed by the full 9-bit mode so that modes
    // which alias in the low bits (0x14 vs 0x94) can never collide.
    // ------------------------------------------------------------------
    // Three 512-entry parameter files, one per channel register.
    //
    // These MUST be read synchronously. Reading them combinationally makes
    // Quartus build 512-deep register files with 512-way muxes -- 8192 flops
    // each. That went unnoticed while only src_file was ever read (the tilemap
    // and palette lengths are hardcoded), because the other two were optimised
    // away entirely; adding the fill mode read all three and the design jumped
    // from 34% to 43% of the device and broke hold timing.
    //
    // A registered read costs nothing here: dma_mode is selected by the 0x47E
    // write, which always precedes the 0x6FC trigger by many CPU cycles, so the
    // outputs are already valid when a transfer starts.
    logic [15:0] src_file  [0:511];
    logic [15:0] size_file [0:511];
    logic [15:0] dst_file  [0:511];
    logic [15:0] src_q, size_q, dst_q;

    always_ff @(posedge clk) begin
        src_q  <= src_file [dma_mode];
        size_q <= size_file[dma_mode];
        dst_q  <= dst_file [dma_mode];
    end

    logic [8:0]  dma_mode;
    logic [15:0] fill_v1, fill_v2;   // 0x428 / 0x42A, the dword written by a fill

    // Pending-request flags, not pulses: the triggers are one-clock strobes,
    // so a request that arrives while a transfer is in flight has to be held
    // rather than dropped. Cleared only when the engine accepts it.
    logic        trigger;
    logic        spr_trigger;
    logic        take_dma;
    logic        take_spr;

    always_ff @(posedge clk) begin
        if (reset) begin
            dma_mode    <= 9'd0;
            trigger     <= 1'b0;
            spr_trigger <= 1'b0;
        end else begin
            if (take_dma) trigger     <= 1'b0;
            if (take_spr) spr_trigger <= 1'b0;

            if (dma_trig) trigger     <= 1'b1;
            if (spr_trig) spr_trigger <= 1'b1;

            if (reg_we) begin
                case (reg_addr)
                    11'h428: fill_v1             <= reg_data;
                    11'h42a: fill_v2             <= reg_data;
                    11'h47e: dma_mode            <= reg_data[8:0];
                    11'h478: src_file [dma_mode] <= reg_data;
                    11'h47a: size_file[dma_mode] <= reg_data;
                    11'h47c: dst_file [dma_mode] <= reg_data;
                    default: ;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // Transfer engine
    // ------------------------------------------------------------------
    typedef enum logic [2:0] { IDLE, FETCH, RUN, DRAIN, FILL } state_t;
    state_t state;

    // The sprite latch wins a tie; the DMA request stays pending behind it.
    assign take_spr = (state == IDLE) &  spr_trigger;
    assign take_dma = (state == IDLE) & ~spr_trigger & trigger;

    logic [8:0]  mode_r;
    logic [15:0] src_word;      // work RAM word address, counts up
    logic [12:0] dst_index;     // destination index, counts up
    logic [12:0] words_left;

    // Read data arrives two clocks after the address, so carry the
    // destination index alongside it through a matching two-deep pipeline.
    logic [12:0] dst_pipe [0:1];
    logic [1:0]  vld_pipe;

    wire is_tilemap = (mode_r == MODE_TILEMAP);
    wire is_palette = (mode_r == MODE_PALETTE);
    wire is_sprite  = (mode_r == MODE_SPRITE);

    assign ram_addr = src_word;
    assign ram_req  = (state == RUN);
    assign busy     = (state != IDLE);

    // A fill writes alternating v1/v2 as little-endian dwords. The start address
    // is src<<6, i.e. 64-byte aligned, so the low bit of the word address is the
    // dword half: even -> v1, odd -> v2.
    assign ram_we    = (state == FILL);
    assign ram_wdata = src_word[0] ? fill_v2 : fill_v1;

    // The write lands when the pipeline's oldest stage is valid.
    wire        wr_valid = vld_pipe[1];
    wire [12:0] wr_index = dst_pipe[1];

    assign vram_addr = wr_index;
    assign vram_data = ram_data;
    assign vram_we   = wr_valid & is_tilemap;

    assign cram_addr = wr_index[10:0];
    assign cram_data = ram_data;
    assign cram_we   = wr_valid & is_palette;

    assign sprram_addr = wr_index[10:0];
    assign sprram_data = ram_data;
    assign sprram_we   = wr_valid & is_sprite;

    always_ff @(posedge clk) begin
        if (reset) begin
            state         <= IDLE;
            vld_pipe      <= 2'b00;
            dma_unknown   <= 1'b0;
            unknown_mode  <= 9'd0;
            unknown_valid <= 1'b0;
        end else begin
            dma_unknown <= 1'b0;

            // Advance the read pipeline whenever the engine is running or
            // draining, so the last two words still get written.
            if (state == RUN || state == DRAIN) begin
                vld_pipe    <= {vld_pipe[0], (state == RUN)};
                dst_pipe[1] <= dst_pipe[0];
                dst_pipe[0] <= dst_index;
            end else begin
                vld_pipe <= 2'b00;
            end

            case (state)
                IDLE: begin
                    if (take_spr) begin
                        // Sprite RAM is at a fixed work RAM address, so this
                        // channel takes no parameters at all.
                        mode_r     <= MODE_SPRITE;
                        src_word   <= 16'h6000;          // 0xC000 >> 1
                        words_left <= SPRITE_WORDS[12:0];
                        dst_index  <= 13'd0;
                        state      <= FETCH;
                    end else if (take_dma) begin
                        mode_r <= dma_mode;
                        // Synchronous read of the selected channel's slot.
                        case (dma_mode)
                            MODE_TILEMAP: begin
                                // src 0x0CFC0 is rewritten to 0xD000; see header.
                                // word address = (reg << 6) >> 1 = reg << 5
                                src_word   <= (src_q == 16'h033f)
                                              ? 16'h6800                        // 0xD000 >> 1
                                              : {src_q[10:0], 5'b0};
                                words_left <= TILEMAP_WORDS[12:0];
                                dst_index  <= 13'd0;
                                state      <= FETCH;
                            end
                            MODE_PALETTE: begin
                                // 0x1F000 >> 1 = 0xF800, so reg 0x7C0 needs all 11 bits
                                src_word   <= {src_q[10:0], 5'b0};
                                // Honour the requested length -- see pal_req_words.
                                words_left <= (pal_req_words > PALETTE_WORDS)
                                              ? PALETTE_WORDS[12:0]
                                              : pal_req_words[12:0];
                                dst_index  <= 13'd0;
                                state      <= FETCH;
                            end
                            default: begin
                                if (is_fill_mode) begin
                                    // MAME's dma_fill() silently returns when
                                    // dst is non-zero, so that is a no-op and
                                    // NOT an unknown mode.
                                    if (dst_q == 16'd0) begin
                                        // address = src<<6 bytes = src<<5 words
                                        src_word   <= {src_q[10:0], 5'b0};
                                        // length = (size+1)<<5 bytes = (size+1)<<4 words
                                        words_left <= (size_q[8:0] + 9'd1) << 4;
                                        state      <= FILL;
                                    end
                                end else if (mame_has_behaviour) begin
                                    dma_unknown <= 1'b1;
                                    if (!unknown_valid) begin
                                        unknown_mode  <= dma_mode;
                                        unknown_valid <= 1'b1;
                                    end
                                end
                            end
                        endcase
                    end
                end

                FETCH: state <= RUN;

                RUN: begin
                    src_word  <= src_word + 16'd1;
                    dst_index <= dst_index + 13'd1;
                    words_left <= words_left - 13'd1;
                    if (words_left == 13'd1) state <= DRAIN;
                end

                FILL: begin
                    src_word   <= src_word + 16'd1;
                    words_left <= words_left - 13'd1;
                    if (words_left == 13'd1) state <= IDLE;
                end

                DRAIN: begin
                    // Two extra clocks to flush the read pipeline.
                    if (!vld_pipe[0] && !vld_pipe[1]) state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
