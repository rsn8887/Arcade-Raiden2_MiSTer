//============================================================================
//  Raiden II - main CPU subsystem
//
//  NEC V30 @ 16 MHz + work RAM + banked program ROM + vblank IRQ.
//
//  CPU core is nec_core (V33) from Arcade-IremM92_MiSTer by Martin Donlon
//  (wickerwaka), GPL-2.0. Its physical_addr() already zero-extends a 20-bit
//  segmented address to 24 bits -- i.e. no address-expansion unit -- so it
//  behaves as a V30 for addressing purposes, and opcodes.yaml covers the full
//  NEC V-series ISA (ADD4S/ROL4/TEST1/INS/EXT/REPC...). What it does NOT match
//  is V30 bus timing; swapping in the VHDL V30 from Arcade-Raiden/M72 later is
//  the accuracy path, which is why the CPU sits behind this wrapper.
//
//  Memory map ground truth: MAME src/mame/seibu/raiden2.cpp (LGPL-2.1+).
//============================================================================

module raiden2_main (
    input  logic        clk,          // clk_sys, 32 MHz
    input  logic        reset,
    input  logic        cpu_ce,       // 32 MHz tick -> two-phase CE gives 16 MHz V30

    input  logic        vblank,       // rising edge raises the single IRQ

    // Program ROM port (SDRAM on hardware, flat memory in sim)
    output logic [20:0] rom_addr,   // 21 bits: Raiden DX banks past 1 MB
    output logic        rom_req,
    input  logic [15:0] rom_data,
    input  logic        rom_ready,

    // Cabinet inputs (active low on hardware)
    input  logic [15:0] dsw,
    input  logic [15:0] p1p2,
    input  logic [15:0] system,

    // Register-window bus for the COP / CRTC / SEI252 / sound blocks.
    //
    // reg_we is a one-clock write strobe, reg_rd a level held for the cycle the
    // CPU samples. reg_be is {upper lane, lower lane}, which several registers
    // need: MAME reaches them through umask16() or a u8 handler, and 0x470 only
    // updates the FG bank when the high byte is written.
    //
    // A block returning read data drives reg_din and raises reg_din_oe for the
    // matching reg_rd; anything not claimed reads back 0.
    output logic [19:0] reg_addr,
    output logic [15:0] reg_dout,
    output logic  [1:0] reg_be,
    output logic        reg_we,
    output logic        reg_rd,
    input  logic [15:0] reg_din,
    input  logic        reg_din_oe,

    // Decoded chip selects, so external blocks never re-decode the window.
    output logic        cop_cs,
    input  logic        game_dx,     // 0 = Raiden II, 1 = Raiden DX
    input  logic  [3:0] dx_prg_bank, // DX banks from 0x470 (video_regs)
    output logic        copbank_cs,
    output logic        crtc_cs,
    output logic        sprite_cs,
    output logic        sprbuf_cs,
    output logic        sprprot_cs,
    output logic        tilebank_cs,
    output logic        copsort_cs,
    output logic        sound_cs,
    output logic        sprprot_rd_cs,

    // Trace taps for the Verilator harness
    // Work-RAM write port tap. Watches the FINAL mux, after CPU and COP
    // arbitration, so a watchpoint built on it sees every writer -- the CPU
    // bus taps below miss COP DMA writes entirely, which matters because the
    // COP's fill mode writes work RAM with arbitrary values.
    output logic        dbg_wram_we,
    output logic [15:0] dbg_wram_addr,   // word address
    output logic [15:0] dbg_wram_wdata,
    output logic        dbg_wram_cop,    // 1 = COP sourced this write

    output logic [19:0] dbg_addr,
    output logic [19:0] dbg_pc,
    output logic [15:0] dbg_es,      // ES/DS1 -- the segment `rep stosw` writes through
    output logic [15:0] dbg_data,
    output logic        dbg_mem_rd,
    output logic        dbg_mem_wr,
    output logic        dbg_intack,
    output logic        dbg_dma_busy,
    // Which of the three gates in cpu_run is holding the CPU. The wedge shows
    // an IRQ handler whose call into 0x9815C never returns; if the CPU is
    // simply held off the bus there, this names the culprit in one deploy
    // instead of another round of guessing at the software.
    output logic  [2:0] dbg_stall_src,   // {cmd_busy, dma_busy, ~rom_ready}
    output logic        dbg_dma_unknown,
    output logic        dbg_cmd_unknown,
    output logic  [8:0] dbg_unknown_mode,
    output logic        dbg_unknown_valid,

    // Video-side read ports on the COP's destination buffers, for the
    // SEI0200 / SEI360 blocks (and for the harness to dump a frame).
    input  logic [12:0] vram_rd_addr,
    output logic [15:0] vram_rd_data,
    input  logic [10:0] cram_rd_addr,
    output logic [15:0] cram_rd_data,
    // Second CRAM read port. The SEI360 mixer draws blended palette entries at
    // 50% over whatever is behind them, so it needs the top colour and the one
    // under it in the same cycle. A dual-port BRAM has no third port, so CRAM
    // is mirrored below -- 32 kbit, against plenty of headroom.
    input  logic [10:0] cram_rd2_addr,
    output logic [15:0] cram_rd2_data,
    input  logic [10:0] sprram_rd_addr,
    output logic [15:0] sprram_rd_data,
    // #73 beam probe: COP command trigger strobes (see raiden2_cop_cmd.sv)
    output logic        dbg_cmd_any,
    output logic        dbg_cmd_0205
);

    //------------------------------------------------------------------
    // Two-phase clock enable. nec_core wants alternating ce_1 / ce_2;
    // one full CPU cycle is a ce_1 followed by a ce_2.
    //------------------------------------------------------------------
    logic ce_toggle;
    logic ce_1, ce_2;
    logic dma_busy;
    // The COP masters work RAM during a transfer, so the CPU is held off the
    // bus for its duration. Real COP timing has never been measured; MAME does
    // the whole transfer instantaneously mid-instruction. Stalling is the
    // conservative model -- see raiden2_cop_dma.sv.
    wire  cpu_run = cpu_ce & rom_ready & ~dma_busy & ~cmd_busy & ~spr_busy & ~itoa_busy & ~wram_clr;

    // Deliberately not qualified by cpu_ce: a stalled CPU is one held by a
    // gate, not one merely between clock enables.
    assign dbg_stall_src = {cmd_busy, dma_busy, ~rom_ready};

    always_ff @(posedge clk) begin
        if (reset) begin
            ce_toggle <= 1'b0;
            ce_1      <= 1'b0;
            ce_2      <= 1'b0;
        end else begin
            ce_1 <= 1'b0;
            ce_2 <= 1'b0;
            if (cpu_run) begin
                ce_toggle <= ~ce_toggle;
                ce_1      <=  ce_toggle;
                ce_2      <= ~ce_toggle;
            end
        end
    end

    //------------------------------------------------------------------
    // CPU
    //------------------------------------------------------------------
    logic [23:0] cpu_addr;
    logic [15:0] cpu_dout, cpu_din;
    logic        cpu_n_ube, cpu_r_w, cpu_m_io;
    logic        cpu_busst0, cpu_busst1, cpu_n_bcyst, cpu_n_dstb;

    logic        int_req;
    logic        intack_d;    // INTA cycles come in pairs
    logic        inta_seen;   // first of the pair has passed

    V33 v30 (
        .clk        (clk),
        .ce_1       (ce_1),
        .ce_2       (ce_2),

        .reset      (reset),
        .hldrq      (1'b0),
        .n_ready    (1'b0),
        .bs16       (1'b0),

        .hldak      (),
        .n_buslock  (),
        .n_ube      (cpu_n_ube),
        .r_w        (cpu_r_w),
        .m_io       (cpu_m_io),
        .busst0     (cpu_busst0),
        .busst1     (cpu_busst1),
        .aex        (),
        .n_bcyst    (cpu_n_bcyst),
        .n_dstb     (cpu_n_dstb),

        .intreq     (int_req),
        .n_nmi      (1'b1),

        .n_cpbusy   (1'b1),
        .n_cperr    (1'b1),
        .cpreq      (1'b0),

        .dbg_pc     (dbg_pc),
        .dbg_es     (dbg_es),

        .addr       (cpu_addr),
        .dout       (cpu_dout),
        .din        (cpu_din),

        .turbo      (1'b0)
    );

    // Bus cycle decode, same encoding M92 uses.
    wire MRD    =  cpu_m_io &  cpu_r_w & ~cpu_busst1;
    wire MWR    =  cpu_m_io & ~cpu_r_w & ~cpu_busst1 &  cpu_busst0 & ~cpu_n_dstb;
    wire INTACK = ~cpu_m_io &  cpu_r_w & ~cpu_busst1 & ~cpu_busst0 & ~cpu_n_dstb;

    // MWR is a level that spans a whole write cycle, and a block that stalls
    // the CPU (the COP DMA) freezes it mid-cycle -- so it stays asserted for
    // the entire transfer. Anything edge-triggered off a register write must
    // use this one-clock strobe instead, or it re-fires the moment the engine
    // goes idle. RAM and bank writes are idempotent and keep using the level.
    logic MWR_d;
    always_ff @(posedge clk) MWR_d <= reset ? 1'b0 : MWR;
    wire MWR_pulse = MWR & ~MWR_d;

    wire [19:0] addr = cpu_addr[19:0];

    //------------------------------------------------------------------
    // Address decode
    //------------------------------------------------------------------
    logic ram_cs, rom_cs;
    logic [20:0] decoded_rom_addr;   // 21 bits: DX banks past 1 MB
    logic reg_cs;
    logic prgbank_cs, copdma_cs;
    logic dsw_cs, p1p2_cs, system_cs;

    logic [3:0] prg_bank;

    raiden2_addr_decode decode (
        .addr          (addr),
        .prg_bank      (game_dx ? dx_prg_bank : prg_bank),
        .game_dx       (game_dx),
        .ram_cs        (ram_cs),
        .rom_cs        (rom_cs),
        .rom_addr      (decoded_rom_addr),
        .reg_cs        (reg_cs),
        .cop_cs        (cop_cs),
        .copbank_cs    (copbank_cs),
        .crtc_cs       (crtc_cs),
        .sprite_cs     (sprite_cs),
        .sprbuf_cs     (sprbuf_cs),
        .sprprot_cs    (sprprot_cs),
        .prgbank_cs    (prgbank_cs),
        .tilebank_cs   (tilebank_cs),
        .copdma_cs     (copdma_cs),
        .copsort_cs    (copsort_cs),
        .sound_cs      (sound_cs),
        .dsw_cs        (dsw_cs),
        .p1p2_cs       (p1p2_cs),
        .system_cs     (system_cs),
        .sprprot_rd_cs (sprprot_rd_cs)
    );

    assign rom_addr = decoded_rom_addr;
    assign rom_req  = rom_cs & MRD;

    //------------------------------------------------------------------
    // Program ROM bank: byte write to 0x6CB, bit 7, inverted.
    // raiden2_bank_w(): entry = ~data[7], so data[7]=1 selects ROM 0x00000.
    // MACHINE_RESET_MEMBER(raiden2_state,raiden2) sets entry 1, which makes
    // the window identity-mapped (CPU 0x20000 -> ROM 0x20000) out of reset.
    //------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            prg_bank <= 4'b0001;
        end else if (prgbank_cs & MWR & ~cpu_n_ube) begin
            // 0x6CB is the odd byte of the 0x6CA word, so it always arrives on
            // the upper lane -- true both for a byte write to 0x6CB and for a
            // word write to 0x6CA.
            prg_bank <= {3'b000, ~cpu_dout[15]};
        end
    end

    //------------------------------------------------------------------
    // Work RAM: 0x00000-0x1FFFF minus the 0x400-0x7FF register window.
    // Split into two byte lanes so Quartus infers M10K cleanly and byte
    // writes need no read-modify-write. 128 KB total.
    //------------------------------------------------------------------
    logic [15:0] ram_dout;
    logic [15:0] dma_ram_addr;
    logic [15:0] dma_ram_wdata;
    logic        dma_ram_we;

    // Three masters share work RAM, in strict priority: the COP command engine,
    // then the COP DMA engine, then the CPU. The two COP engines are never busy
    // at once (both are triggered by CPU writes and each stalls the CPU for its
    // duration), so the priority only has to be well defined, not fair.
    //
    // The command engine is the first master that WRITES work RAM -- the DMA
    // engine only ever reads it, and writes into the video buffers. So the write
    // data and the byte lanes are muxed too, not just the address.
    //
    // Write enables must stay gated on the COP being idle: a stalled CPU keeps
    // MWR asserted for the whole transfer, which would otherwise write
    // repeatedly at whatever address the COP is currently reading.
    //------------------------------------------------------------------
    // COP sprite protection / display-list builder (#61 tier 1). A fourth
    // work-RAM master, arbitrated below under the DMA. It owns dst1 because
    // the engine ADVANCES it by 8 per accepted sprite; a latch here could only
    // ever return what the CPU last wrote. Verified against a C model of MAME's
    // sprite_prot_src_w by `make sprprot-run` (6/6).
    //------------------------------------------------------------------
    logic        spr_busy;
    logic [15:0] spr_ram_addr, spr_ram_wdata;
    logic        spr_ram_we;
    logic [15:0] sprprot_dst1, sprprot_off, sprprot_srcseg, sprprot_maxx;

    raiden2_sprprot u_sprprot (
        .clk       (clk),          .reset     (reset),
        .reg_addr  (addr[10:0]),   .reg_data  (cpu_dout),
        .reg_we    (reg_cs & MWR_pulse),
        .ram_addr  (spr_ram_addr), .ram_data  (ram_dout),
        .ram_wdata (spr_ram_wdata),.ram_we    (spr_ram_we),
        .dst1      (sprprot_dst1), .spr_off   (sprprot_off),
        .src_seg   (sprprot_srcseg),.maxx     (sprprot_maxx),
        .busy      (spr_busy)
    );

    //------------------------------------------------------------------
    // COP integer-to-BCD (score display, #63). A full attract run reads the
    // digit results 120 times, so this block is genuinely used. Conversion is
    // 32 clocks (double dabble); busy joins cop_holds_bus so the CPU cannot
    // read half-converted digits -- MAME's bcd_update() is instantaneous.
    //------------------------------------------------------------------
    logic        itoa_busy;
    logic [15:0] itoa_rd_data;

    raiden2_cop_itoa u_itoa (
        .clk      (clk),        .reset   (reset),
        .reg_addr (addr[10:0]), .reg_data(cpu_dout), .reg_we (reg_cs & MWR_pulse),
        .rd_idx   (addr[9:1] - 9'h0C8),
        .rd_data  (itoa_rd_data),
        .busy     (itoa_busy)
    );

    wire        cop_holds_bus = cmd_busy | dma_busy | spr_busy | itoa_busy;

    // ---- work RAM clear on reset --------------------------------------
    // MAME zero-fills work RAM; FPGA block RAM zeroes only on configuration, so
    // a warm reset leaves stale contents. The fade worker walks a node list via
    // node->next at +0x48 -- a field its constructor never writes -- so a
    // non-zero leftover there makes the walk run forever. Clearing at reset
    // matches the emulated power-on state. 65536 words = ~1 ms at 64 MHz.
    logic        wram_clr;      // high while clearing
    logic [15:0] clr_addr;
    always_ff @(posedge clk) begin
        if (reset) begin
            clr_addr <= 16'd0;
            wram_clr <= 1'b1;
        end else if (wram_clr) begin
            clr_addr <= clr_addr + 16'd1;
            if (&clr_addr) wram_clr <= 1'b0;
        end
    end

    wire [15:0] ram_word_addr = wram_clr ? clr_addr
                              : cmd_busy ? cmd_ram_addr
                              : dma_busy ? dma_ram_addr
                              : spr_busy ? spr_ram_addr
                                         : addr[16:1];   // 16-bit word address

    wire [15:0] ram_wdata = wram_clr ? 16'd0
                          : cmd_busy ? cmd_ram_wdata
                          : dma_busy ? dma_ram_wdata
                          : spr_busy ? spr_ram_wdata : cpu_dout;

    // The command engine writes words for most ops but a single byte for the
    // 0x6200 angle macro, so its lane enables come from the engine. The DMA
    // engine writes work RAM only for the fill mode, and always whole words.
    wire        ram_we_lo = wram_clr ? 1'b1
                          : cmd_busy ? (cmd_ram_we & cmd_ram_be[0])
                          : dma_busy ? dma_ram_we
                          : spr_busy ? spr_ram_we
                                     : (ram_cs & MWR & ~addr[0]   & ~cop_holds_bus);
    wire        ram_we_hi = wram_clr ? 1'b1
                          : cmd_busy ? (cmd_ram_we & cmd_ram_be[1])
                          : dma_busy ? dma_ram_we
                          : spr_busy ? spr_ram_we
                                     : (ram_cs & MWR & ~cpu_n_ube & ~cop_holds_bus);

    singleport_ram #(.widthad(16), .width(8), .name("WRAM0")) wram_lo (
        .clock   (clk),
        .address (ram_word_addr),
        .data    (ram_wdata[7:0]),
        .wren    (ram_we_lo),
        .q       (ram_dout[7:0])
    );

    singleport_ram #(.widthad(16), .width(8), .name("WRAM1")) wram_hi (
        .clock   (clk),
        .address (ram_word_addr),
        .data    (ram_wdata[15:8]),
        .wren    (ram_we_hi),
        .q       (ram_dout[15:8])
    );

    //------------------------------------------------------------------
    // COP DMA + the video-side buffers it fills
    //------------------------------------------------------------------
    logic [12:0] vram_wr_addr;    logic [15:0] vram_wr_data;    logic vram_we;
    logic [10:0] cram_wr_addr;    logic [15:0] cram_wr_data;    logic cram_we;
    logic [10:0] sprram_wr_addr;  logic [15:0] sprram_wr_data;  logic sprram_we;

    raiden2_cop_dma cop_dma (
        .clk         (clk),
        .reset       (reset),
        .reg_addr    (addr[10:0]),
        .reg_data    (cpu_dout),
        .reg_we      (reg_cs & MWR_pulse),
        .dma_trig    (copdma_cs & MWR_pulse),
        .spr_trig    (sprbuf_cs & MWR_pulse),
        .ram_addr    (dma_ram_addr),
        .ram_req     (),
        .ram_data    (ram_dout),
        .ram_wdata   (dma_ram_wdata),
        .ram_we      (dma_ram_we),
        .vram_addr   (vram_wr_addr),
        .vram_data   (vram_wr_data),
        .vram_we     (vram_we),
        .cram_addr   (cram_wr_addr),
        .cram_data   (cram_wr_data),
        .cram_we     (cram_we),
        .sprram_addr (sprram_wr_addr),
        .sprram_data (sprram_wr_data),
        .sprram_we   (sprram_we),
        .busy        (dma_busy),
        .dma_unknown (dbg_dma_unknown),
        .unknown_mode (dbg_unknown_mode),
        .unknown_valid(dbg_unknown_valid)
    );

    assign dbg_dma_busy = dma_busy | cmd_busy;

    //------------------------------------------------------------------
    // COP command engine -- the math/collision half of the COP.
    //
    // Shares the register window with everything else in 0x400-0x7FF and
    // decodes its own addresses; see raiden2_cop_cmd.sv for the map. It masters
    // work RAM through the arbiter above.
    //------------------------------------------------------------------
    logic [15:0] cmd_ram_addr, cmd_ram_wdata;
    logic  [1:0] cmd_ram_be;
    logic        cmd_ram_rd, cmd_ram_we;
    logic [15:0] cop_reg_din;
    logic        cop_reg_din_oe;
    logic        cmd_busy;

    raiden2_cop_cmd cop_cmd (
        .clk        (clk),
        .reset      (reset),

        .reg_addr   (addr[10:0]),
        .reg_data   (cpu_dout),
        .reg_be     ({~cpu_n_ube, ~addr[0]}),
        .reg_we     (reg_cs & MWR_pulse),
        .reg_rd     (reg_cs & MRD),

        .reg_din    (cop_reg_din),
        .reg_din_oe (cop_reg_din_oe),

        .ram_addr   (cmd_ram_addr),
        .ram_rd     (cmd_ram_rd),
        .ram_we     (cmd_ram_we),
        .ram_be     (cmd_ram_be),
        .ram_wdata  (cmd_ram_wdata),
        .ram_rdata  (ram_dout),

        .busy       (cmd_busy),
        .cmd_unknown(dbg_cmd_unknown),
        .dbg_cmd_any(dbg_cmd_any),
        .dbg_cmd_0205(dbg_cmd_0205)
    );

    // Tilemap private buffer: 0x1400 words. BG/FG/MID/TXT all live in here,
    // at the same relative offsets they occupy in work RAM from 0xD000.
    dualport_ram #(.widthad(13), .width(16)) tilemap_buf (
        .clock_a   (clk),
        .address_a (vram_wr_addr),
        .data_a    (vram_wr_data),
        .wren_a    (vram_we),
        .q_a       (),
        .clock_b   (clk),
        .address_b (vram_rd_addr),
        .data_b    (16'd0),
        .wren_b    (1'b0),
        .q_b       (vram_rd_data)
    );

    // SEI252's latched copy of sprite RAM: 512 entries x 8 bytes. Latching it
    // rather than reading work RAM live is what gives sprites their one-frame
    // delay on real hardware.
    dualport_ram #(.widthad(11), .width(16)) sprite_buf (
        .clock_a   (clk),
        .address_a (sprram_wr_addr),
        .data_a    (sprram_wr_data),
        .wren_a    (sprram_we),
        .q_a       (),
        .clock_b   (clk),
        .address_b (sprram_rd_addr),
        .data_b    (16'd0),
        .wren_b    (1'b0),
        .q_b       (sprram_rd_data)
    );

    // CRAM: 2048 colours, xBGR-555.
    dualport_ram #(.widthad(11), .width(16)) cram (
        .clock_a   (clk),
        .address_a (cram_wr_addr),
        .data_a    (cram_wr_data),
        .wren_a    (cram_we),
        .q_a       (),
        .clock_b   (clk),
        .address_b (cram_rd_addr),
        .data_b    (16'd0),
        .wren_b    (1'b0),
        .q_b       (cram_rd_data)
    );

    // Mirror of the above, written identically, existing only to give the
    // mixer a second simultaneous read. Both copies share one write port, so
    // they cannot drift apart.
    dualport_ram #(.widthad(11), .width(16)) cram_mirror (
        .clock_a   (clk),
        .address_a (cram_wr_addr),
        .data_a    (cram_wr_data),
        .wren_a    (cram_we),
        .q_a       (),
        .clock_b   (clk),
        .address_b (cram_rd2_addr),
        .data_b    (16'd0),
        .wren_b    (1'b0),
        .q_b       (cram_rd2_data)
    );

    //------------------------------------------------------------------
    // Register window. The three input ports are wired straight to the CPU on
    // the board, so they answer here; everything else is answered by whichever
    // external block claims the cycle with reg_din_oe. Unclaimed reads return
    // 0, which is what MAME's unmapped handler gives for this space -- note
    // the Seibu sound window is an exception and returns 0xFF once it exists.
    //------------------------------------------------------------------
    // reg_we is a one-clock strobe; reg_rd stays a level so the read mux is
    // stable for the whole cycle the CPU samples it.
    assign reg_addr = addr;
    assign reg_dout = cpu_dout;
    assign reg_be   = {~cpu_n_ube, ~addr[0]};
    assign reg_we   = reg_cs & MWR_pulse;
    assign reg_rd   = reg_cs & MRD;

    //------------------------------------------------------------------
    // Sprite-prot destination (HANDOFF #61).
    //
    // MAME src/mame/seibu/raiden2.cpp:
    //     map(0x006c6, 0x006c7).w(sprite_prot_dst1_w);   // m_dst1 = data
    //     map(0x00762, 0x00763).r(sprite_prot_dst1_r);   // return m_dst1
    //
    // The game writes the sprite-list base here, the COP advances it, and then
    // reads it back at 0x762 and uses it as the write pointer:
    //     ae541: mov di,[0x762]
    //     ae545: mov [9F9C],di
    // 0x762 was decoded (sprprot_rd_cs) and routed out of this module but never
    // driven, so every readback returned 0x0000 and the sprite-list builder at
    // 0xA4468 wrote 8-byte records from address 0 -- straight over interrupt
    // vector 0x30 at byte 0xC0. The next vblank then vectored into a data table
    // and the game died. That is the whole of #61.
    //
    // NOTE: MAME also does `m_dst1 += 8` per sprite inside the sprite-prot DMA,
    // which this core does not implement at all. Latching the value restores a
    // sane pointer and stops the IVT corruption; sprite LIST PLACEMENT may still
    // differ until that DMA exists. Do not read this as the sprite-prot block
    // being complete.
    logic [15:0] reg_rdata;
    always_comb begin
        if      (dsw_cs)         reg_rdata = dsw;
        else if (p1p2_cs)        reg_rdata = p1p2;
        else if (system_cs)      reg_rdata = system;
        // 0x590-0x599: itoa digits, two per word. addr[9:1] 0xC8..0xCC.
        else if (cop_cs && addr[9:1] >= 9'h0C8 && addr[9:1] <= 9'h0CC)
                                 reg_rdata = itoa_rd_data;
        else if (sprprot_rd_cs)  reg_rdata = sprprot_dst1;
        // 0x6C0 / 0x6C2 / 0x6DC are r/w in MAME; the rest is write-only.
        else if (sprprot_cs && addr[9:1] == 9'h160) reg_rdata = sprprot_off;
        else if (sprprot_cs && addr[9:1] == 9'h161) reg_rdata = sprprot_srcseg;
        else if (sprprot_cs && addr[9:1] == 9'h16E) reg_rdata = sprprot_maxx;
        // The COP command engine answers from inside this module; external
        // blocks (raiden2_video_regs) answer via reg_din/reg_din_oe. The two
        // claim disjoint addresses, so the order between them does not matter.
        else if (cop_reg_din_oe) reg_rdata = cop_reg_din;
        else if (reg_din_oe)     reg_rdata = reg_din;
        else                     reg_rdata = 16'h0000;
    end

    //------------------------------------------------------------------
    // Read mux. INTACK supplies the interrupt vector externally: MAME's
    // vector_r() returns 0xc0/4 = 0x30, so the handler pointer is at 0xC0.
    //------------------------------------------------------------------
    always_comb begin
        if      (INTACK) cpu_din = 16'h0030;
        else if (reg_cs) cpu_din = reg_rdata;
        else if (ram_cs) cpu_din = ram_dout;
        else if (rom_cs) cpu_din = rom_data;
        else             cpu_din = 16'hFFFF;
    end

    //------------------------------------------------------------------
    // Single vblank IRQ, held until acknowledged (irq0_line_hold).
    //------------------------------------------------------------------
    logic vblank_d;
    always_ff @(posedge clk) begin
        if (reset) begin
            int_req   <= 1'b0;
            vblank_d  <= 1'b0;
            intack_d  <= 1'b0;
            inta_seen <= 1'b0;
        end else begin
            vblank_d  <= vblank;
            intack_d  <= INTACK;
            // The V30 runs TWO INTA bus cycles per acknowledge and reads the
            // vector on the second. INTACK here is a level, so clearing on it
            // dropped intreq during the first cycle -- the request was gone
            // before the vector was fetched. Count the two cycles and clear
            // after the second, which is what a real 8259 does (the reference
            // M92 core gets this for free from its PIC).
            if (vblank & ~vblank_d) begin
                int_req  <= 1'b1;
                inta_seen <= 1'b0;
            end else if (INTACK & ~intack_d) begin
                if (inta_seen) begin
                    int_req   <= 1'b0;
                    inta_seen <= 1'b0;
                end else begin
                    inta_seen <= 1'b1;
                end
            end
        end
    end

    //------------------------------------------------------------------
    // Trace taps
    //------------------------------------------------------------------
    assign dbg_wram_we    = (ram_we_lo | ram_we_hi) & ~wram_clr;
    assign dbg_wram_addr  = ram_word_addr;
    assign dbg_wram_wdata = ram_wdata;
    assign dbg_wram_cop   = cop_holds_bus;

    assign dbg_addr   = addr;
    assign dbg_data   = MWR ? cpu_dout : cpu_din;
    assign dbg_mem_rd = MRD;
    assign dbg_mem_wr = MWR;
    assign dbg_intack = INTACK;

endmodule
