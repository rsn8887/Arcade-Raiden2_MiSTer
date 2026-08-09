//============================================================================
//  Raiden II - Seibu sound subsystem
//
//  Z80 + YM2151 + two OKI6295, wired to the mailbox in raiden2_seibu_latch.sv
//  (which is diffed against MAME's seibu_sound device by sim/tb_seibu_latch).
//
//  This matters for more than audio: the coin inputs are read by the Z80 at
//  0x4013 and reported back to the main CPU through the mailbox, so without a
//  running sound CPU the game can never take a credit.
//
//  Ground truth: MAME src/mame/seibu/seibusound.cpp and the raiden2_sound_map
//  in raiden2.cpp:
//      0x0000-0x1FFF  ROM, fixed
//      0x2000-0x27FF  RAM, 2 KB
//      0x4000         pending_w        0x4001  irq_clear_w
//      0x4002         rst10_ack_w      0x4003  rst18_ack_w
//      0x4008-0x4009  YM2151
//      0x4010-0x4011  soundlatch_r     0x4012  main_data_pending_r
//      0x4013         coin_r
//      0x4018-0x4019  main_data_w      0x401A  bank_w    0x401B  coin_w
//      0x6000         OKI 1            0x6002  OKI 2
//      0x8000-0xFFFF  banked ROM
//
//  Clocks, from the raiden2 machine config, against a 64 MHz clk_sys:
//      Z80 and YM2151   28.636363/8  = 3.579545 MHz
//      OKI6295          28.636363/28 = 1.022727 MHz, PIN7 high
//  Both are generated with fractional accumulators rather than integer
//  dividers -- 64 MHz divides into neither evenly, and the YM2151's pitch is
//  audibly wrong if its clock is off by the ~0.7% an integer divide would give.
//
//  The sound ROMs are NOT encrypted on this board: raiden2 has no SEI80BU, so
//  unlike some Seibu titles nothing has to be descrambled on the way in.
//============================================================================

module raiden2_sound (
    input  logic        clk,            // clk_sys, 64 MHz
    input  logic        reset,

    // ---- main CPU side of the mailbox (V30 window 0x700-0x71F) --------
    input  logic  [3:0] main_ofs,       // (addr >> 1) within the window
    input  logic  [7:0] main_din,
    input  logic        main_we,        // one-clock strobe
    input  logic        main_rd,
    output logic  [7:0] main_dout,

    // Active low, as the board presents them.
    input  logic  [7:0] coin_in,

    // ---- Z80 program ROM, filled from the ioctl stream ----------------
    input  logic        rom_wr,
    input  logic [15:0] rom_wr_addr,    // word address within the 128 KB region
    input  logic [15:0] rom_wr_data,

    // ---- OKI sample ROM, read over SDRAM ch4 --------------------------
    output logic [24:0] oki_addr,
    output logic        oki_req,
    input  logic [63:0] oki_dout,
    input  logic        oki_ack,

    output logic signed [15:0] audio_out,

    // for the self-test page
    output logic        dbg_z80_running,
    output logic        dbg_ym_write,

    // ---- #65 probe: WHERE does the sound chain stop? ------------------
    // `make sound-run` proves the OKI fetch path is correct and that an idle
    // cache issues exactly 2 ch4 fetches -- which is what the board reports.
    // `make run` proves the main CPU writes a command every frame. So the
    // break is inside the Z80, which no harness here can execute (T80 is
    // VHDL). These four strobes form a decision table:
    //   intack  == 0                     -> interrupts never taken
    //   intack  > 0, latch_rd == 0       -> the ISR never reads the command
    //   latch_rd > 0, bank_exec == 0     -> never enters the banked driver
    //   bank_exec > 0, oki_write == 0    -> driver runs, never plays a sample
    output logic        dbg_oki_write,
    output logic        dbg_intack,
    output logic        dbg_latch_rd,
    output logic        dbg_bank_exec,

    // Round 2: the Z80 is alive but stuck in the low 8 KB. Where, and how far
    // does the RST18 handler get before it stops acking?
    output logic [15:0] dbg_z80_pc,      // last M1 (opcode fetch) address
    output logic        dbg_rst18_ack,   // write to 0x4003
    output logic        dbg_pending_rd   // read of 0x4012
);

    //------------------------------------------------------------------
    // Clock enables
    //------------------------------------------------------------------
    // step = round(f_target / f_clk * 2^24)
    localparam [23:0] STEP_Z80 = 24'd938438;    // 3.579545 MHz
    localparam [23:0] STEP_OKI = 24'd268125;    // 1.022727 MHz

    reg [24:0] acc_z80, acc_oki;
    always_ff @(posedge clk) begin
        acc_z80 <= {1'b0, acc_z80[23:0]} + {1'b0, STEP_Z80};
        acc_oki <= {1'b0, acc_oki[23:0]} + {1'b0, STEP_OKI};
    end
    wire cen_z80 = acc_z80[24];
    wire cen_oki = acc_oki[24];

    // jt51 wants a second enable at half rate.
    reg cen_ym_half;
    always_ff @(posedge clk) if (cen_z80) cen_ym_half <= ~cen_ym_half;
    wire cen_ym_p1 = cen_z80 & cen_ym_half;

    //------------------------------------------------------------------
    // Z80
    //------------------------------------------------------------------
    wire [15:0] z80_addr;
    wire  [7:0] z80_dout;
    reg   [7:0] z80_din;
    wire        z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n, z80_m1_n;

    wire rom_lo_cs = ~z80_mreq_n & (z80_addr[15:13] == 3'b000);    // 0x0000-0x1FFF
    wire ram_cs    = ~z80_mreq_n & (z80_addr[15:11] == 5'b00100);  // 0x2000-0x27FF
    wire reg_cs    = ~z80_mreq_n & (z80_addr[15:5]  == 11'h200);   // 0x4000-0x401F
    wire oki_cs    = ~z80_mreq_n & (z80_addr[15:4]  == 12'h600);   // 0x6000-0x600F
    wire rom_hi_cs = ~z80_mreq_n & z80_addr[15];                   // 0x8000-0xFFFF

    // IM 0: the vector is driven onto the bus during the M1+IORQ cycle.
    wire z80_intack = ~z80_m1_n & ~z80_iorq_n;

    // ---- INTA is a MULTI-CYCLE window, and the vector must not move in it --
    // This was a real bug (HANDOFF #65). `z80_intack` was handed to the latch
    // gated only by cen_z80, so it asserted on EVERY cen_z80 inside the INTA
    // cycle. The first one set rst18_service, which drops `take18`, which
    // collapses the latch's combinational z80_vector from 0xDF to 0x00 -- while
    // the Z80 was still sampling the bus. The CPU latched 0x00 (a NOP) instead
    // of RST 18, so the handler never ran, and because the service flag is
    // cleared only BY that handler, every later interrupt was blocked too.
    // Measured signature: ~6 acknowledges and then permanent silence, with 0
    // reads of the sound latch and 0 OKI writes.
    //
    // Two fixes, both needed:
    //   1. a ONE-SHOT at the start of INTA, so the latch updates its service
    //      flags exactly once per acknowledge;
    //   2. hold the vector for the rest of the window. On the first clock the
    //      live value is still correct (service updates on that same edge);
    //      from the second clock on, the captured copy is driven.
    reg z80_intack_d;
    always_ff @(posedge clk) z80_intack_d <= reset ? 1'b0 : z80_intack;
    wire z80_intack_start = z80_intack & ~z80_intack_d;

    reg [7:0] z80_vec_hold;
    always_ff @(posedge clk)
        if (reset)                 z80_vec_hold <= 8'h00;
        else if (z80_intack_start) z80_vec_hold <= z80_vector;

    wire [7:0] z80_vector_stable = z80_intack_d ? z80_vec_hold : z80_vector;

    wire       z80_int;
    wire [7:0] z80_vector;
    wire       rom_bank;

    T80s u_z80 (
        .RESET_n (~reset),
        .CLK     (clk),
        .CEN     (cen_z80),
        .WAIT_n  (1'b1),
        .INT_n   (~z80_int),
        .NMI_n   (1'b1),
        .BUSRQ_n (1'b1),
        .M1_n    (z80_m1_n),
        .MREQ_n  (z80_mreq_n),
        .IORQ_n  (z80_iorq_n),
        .RD_n    (z80_rd_n),
        .WR_n    (z80_wr_n),
        .RFSH_n  (),
        .HALT_n  (),
        .BUSAK_n (),
        .OUT0    (1'b0),
        .A       (z80_addr),
        .DI      (z80_din),
        .DO      (z80_dout),
        .REG     ()
    );

    //------------------------------------------------------------------
    // Program ROM, 128 KB, filled during the ioctl download
    //------------------------------------------------------------------
    // Region layout, as the MRA builds it:
    //   0x00000  first 32 KB of the ROM   -> Z80 0x0000-0x1FFF reads from here
    //   0x10000  bank 0                   -> Z80 0x8000-0xFFFF
    //   0x18000  bank 1
    wire [16:0] rom_byte_addr = rom_hi_cs ? {1'b1, rom_bank, z80_addr[14:0]}
                                          : {4'd0, z80_addr[12:0]};
    wire [15:0] rom_word;

    dualport_ram #(.widthad(16), .width(16)) z80_rom (
        .clock_a   (clk),
        .address_a (rom_wr_addr),
        .data_a    (rom_wr_data),
        .wren_a    (rom_wr),
        .q_a       (),
        .clock_b   (clk),
        .address_b (rom_byte_addr[16:1]),
        .data_b    (16'd0),
        .wren_b    (1'b0),
        .q_b       (rom_word)
    );
    wire [7:0] rom_byte = rom_byte_addr[0] ? rom_word[15:8] : rom_word[7:0];

    //------------------------------------------------------------------
    // Work RAM, 2 KB
    //------------------------------------------------------------------
    wire [7:0] ram_dout;
    dualport_ram #(.widthad(11), .width(8)) z80_ram (
        .clock_a   (clk),
        .address_a (z80_addr[10:0]),
        .data_a    (z80_dout),
        .wren_a    (ram_cs & ~z80_wr_n & cen_z80),
        .q_a       (ram_dout),
        .clock_b   (clk),
        .address_b (11'd0),
        .data_b    (8'd0),
        .wren_b    (1'b0),
        .q_b       ()
    );

    //------------------------------------------------------------------
    // Seibu mailbox
    //------------------------------------------------------------------
    wire [7:0] latch_dout;
    wire       ym_irq_n;

    raiden2_seibu_latch u_latch (
        .clk(clk), .reset(reset),
        .main_ofs(main_ofs), .main_din(main_din),
        .main_we(main_we), .main_rd(main_rd), .main_dout(main_dout),
        .z80_ofs(z80_addr[4:0]), .z80_din(z80_dout),
        .z80_we(reg_cs & ~z80_wr_n & cen_z80),
        .z80_rd(reg_cs & ~z80_rd_n),
        .z80_dout(latch_dout),
        .coin_in(coin_in),
        .ym_irq(~ym_irq_n),
        .z80_int(z80_int), .z80_intack(z80_intack_start),
        .z80_vector(z80_vector),
        .rom_bank(rom_bank)
    );

    //------------------------------------------------------------------
    // YM2151
    //------------------------------------------------------------------
    wire  [7:0] ym_dout;
    wire signed [15:0] ym_left, ym_right;
    wire        ym_cs_n = ~(reg_cs & (z80_addr[4:1] == 4'h4));   // 0x4008-0x4009

    jt51 u_ym (
        .rst(reset), .clk(clk), .cen(cen_z80), .cen_p1(cen_ym_p1),
        .cs_n(ym_cs_n), .wr_n(z80_wr_n), .a0(z80_addr[0]),
        .din(z80_dout), .dout(ym_dout),
        .ct1(), .ct2(), .irq_n(ym_irq_n),
        .sample(), .left(), .right(),
        .xleft(ym_left), .xright(ym_right)
    );

    //------------------------------------------------------------------
    // Two OKI6295, sharing SDRAM ch4
    //------------------------------------------------------------------
    // Each gets a one-line cache: ADPCM playback walks memory sequentially, so
    // one 8-byte fetch covers eight consecutive reads and ch4 sees very little
    // traffic even with both channels running.
    localparam [24:0] OKI1_BASE = 25'h0180000;
    localparam [24:0] OKI2_BASE = 25'h01C0000;

    wire [17:0] oki1_raddr, oki2_raddr;
    wire  [7:0] oki1_rdata, oki2_rdata;
    wire        oki1_ok, oki2_ok;

    // The line cache lives in its own module so it can be simulated without
    // T80 (VHDL, which Verilator cannot elaborate). `make sound-run` drives
    // this exact instance against a behavioural ch4 responder. See HANDOFF #65.
    raiden2_oki_cache #(
        .OKI1_BASE(OKI1_BASE), .OKI2_BASE(OKI2_BASE)
    ) u_oki_cache (
        .clk(clk), .reset(reset),
        .oki1_raddr(oki1_raddr), .oki2_raddr(oki2_raddr),
        .oki1_rdata(oki1_rdata), .oki2_rdata(oki2_rdata),
        .oki1_ok(oki1_ok),       .oki2_ok(oki2_ok),
        .oki_addr(oki_addr),     .oki_req(oki_req),
        .oki_dout(oki_dout),     .oki_ack(oki_ack)
    );

    wire [7:0] oki1_dout, oki2_dout;
    wire signed [13:0] oki1_snd, oki2_snd;
    wire       oki1_sel = oki_cs & ~z80_addr[1];    // 0x6000
    wire       oki2_sel = oki_cs &  z80_addr[1];    // 0x6002

    jt6295 #(.INTERPOL(1)) u_oki1 (
        .rst(reset), .clk(clk), .cen(cen_oki), .ss(1'b1),
        .wrn(~(oki1_sel & ~z80_wr_n & cen_z80)),
        .din(z80_dout), .dout(oki1_dout),
        .rom_addr(oki1_raddr), .rom_data(oki1_rdata), .rom_ok(oki1_ok),
        .sound(oki1_snd), .sample()
    );

    jt6295 #(.INTERPOL(1)) u_oki2 (
        .rst(reset), .clk(clk), .cen(cen_oki), .ss(1'b1),
        .wrn(~(oki2_sel & ~z80_wr_n & cen_z80)),
        .din(z80_dout), .dout(oki2_dout),
        .rom_addr(oki2_raddr), .rom_data(oki2_rdata), .rom_ok(oki2_ok),
        .sound(oki2_snd), .sample()
    );

    //------------------------------------------------------------------
    // Z80 read mux
    //------------------------------------------------------------------
    always_comb begin
        if      (z80_intack) z80_din = z80_vector_stable;
        else if (rom_lo_cs)  z80_din = rom_byte;
        else if (rom_hi_cs)  z80_din = rom_byte;
        else if (ram_cs)     z80_din = ram_dout;
        else if (~ym_cs_n)   z80_din = ym_dout;
        else if (reg_cs)     z80_din = latch_dout;
        else if (oki1_sel)   z80_din = oki1_dout;
        else if (oki2_sel)   z80_din = oki2_dout;
        else                 z80_din = 8'hFF;
    end

    //------------------------------------------------------------------
    // Mix. MAME routes the YM at 0.50 and each OKI at 0.40; the gains below
    // are 4.4 fixed point, so 0x10 is unity.
    //------------------------------------------------------------------
    wire signed [15:0] oki1_ext = {oki1_snd, 2'b00};
    wire signed [15:0] oki2_ext = {oki2_snd, 2'b00};
    wire signed [15:0] ym_mono  = (ym_left >>> 1) + (ym_right >>> 1);

    jtframe_mixer #(.W0(16), .W1(16), .W2(16), .W3(16), .WOUT(16)) u_mix (
        .rst(reset), .clk(clk), .cen(cen_oki),
        .ch0(ym_mono), .ch1(oki1_ext), .ch2(oki2_ext), .ch3(16'd0),
        .gain0(8'h10), .gain1(8'h0D), .gain2(8'h0D), .gain3(8'h00),
        .mixed(audio_out), .peak()
    );

    //------------------------------------------------------------------
    // Diagnostics
    //------------------------------------------------------------------
    // The Z80 fetching opcodes from more than one address proves it is really
    // executing rather than sitting on a bus that reads back a constant.
    reg [15:0] last_m1_addr;
    always_ff @(posedge clk) begin
        if (reset) begin
            dbg_z80_running <= 1'b0;
            last_m1_addr    <= 16'd0;
        end else if (cen_z80 && ~z80_m1_n && ~z80_mreq_n) begin
            if (last_m1_addr != 16'd0 && last_m1_addr != z80_addr)
                dbg_z80_running <= 1'b1;
            last_m1_addr <= z80_addr;
        end
    end

    assign dbg_ym_write = ~ym_cs_n & ~z80_wr_n & cen_z80;

    // #65 decision table. All four are one-cen_z80 strobes, counted upstream.
    assign dbg_oki_write = oki_cs   & ~z80_wr_n & cen_z80;
    // One count per acknowledge. This used to be `z80_intack & cen_z80`, which
    // fired several times inside a single INTA window and so OVERcounted --
    // the round-1 reading of 3 was really about one interrupt. Now it is
    // directly comparable with MAME (~1579 per 300 frames, tools/oracle_z80.lua).
    assign dbg_intack    = z80_intack_start;
    // soundlatch_r is 0x4010 (z80_ofs 0x10); main_data_pending_r is 0x4012.
    assign dbg_latch_rd  = reg_cs & ~z80_rd_n & cen_z80 & (z80_addr[4:1] == 4'h8);
    // An M1 fetch above 0x8000 means the banked driver body is executing.
    assign dbg_bank_exec = cen_z80 & ~z80_m1_n & ~z80_mreq_n & z80_addr[15];

    // Round 2. rst18_ack_w is 0x4003 (z80_ofs 0x03); irq_clear_w at 0x4001 does
    // the same job, so both are counted -- an ack through either one keeps the
    // interrupt alive, and counting only 0x4003 could read as "never acks".
    assign dbg_rst18_ack  = reg_cs & ~z80_wr_n & cen_z80
                            & (z80_addr[4:0] == 5'h03 || z80_addr[4:0] == 5'h01);
    assign dbg_pending_rd = reg_cs & ~z80_rd_n & cen_z80 & (z80_addr[4:0] == 5'h12);
    assign dbg_z80_pc     = last_m1_addr;

endmodule
