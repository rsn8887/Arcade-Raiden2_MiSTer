//============================================================================
//  Raiden II - Seibu sound latch + Z80 interrupt arbitration (SIE150 side)
//
//  The main-CPU <-> sound-CPU mailbox, and the RST10/RST18 arbitration that
//  decides which vector the Z80 fetches in IM 0.
//
//  WHY THIS BLOCK COMES BEFORE THE FM AND PCM CHIPS:
//
//  On Seibu hardware the coin inputs are wired to the SOUND CPU, not the main
//  CPU -- the Z80 reads them at 0x4013 and reports credits back through this
//  mailbox. The board will not acknowledge a coin until the sound section
//  answers. Confirmed on real hardware by a 2025 repair log (Oguz, Museum of
//  the Game): a Raiden II with every graphics fault fixed and a perfect picture
//  still would not take a coin; the fault was a dead sound RAM, and replacing
//  it made coins work.
//
//  So a core with flawless video and a complete COP still cannot START A GAME
//  without this. It is not an audio nicety; it is the credit path.
//
//  Ground truth: MAME src/mame/shared/seibusound.cpp (BSD-3-Clause) and the
//  raiden2_sound_map in src/mame/seibu/raiden2.cpp (LGPL-2.1+).
//
//  Main CPU side -- a 16-byte window at 0x700-0x71F, low byte of each word:
//    write 0,1  main->sub latch bytes
//    write 4    assert RST18 (a message is waiting)
//    write 2,6  clear sub->main pending, set main->sub pending
//    read  2,3  sub->main latch bytes
//    read  5    main->sub pending flag
//    anything else reads 0xFF
//
//  Z80 side:
//    0x4000 w  pending    -- clear main->sub, set sub->main
//    0x4001 w  irq_clear  -- RST18 end-of-interrupt
//    0x4002 w  rst10_ack  -- RST10 end-of-interrupt
//    0x4003 w  rst18_ack  -- RST18 end-of-interrupt (same as 0x4001)
//    0x4010/1 r  main->sub latch
//    0x4012 r  sub->main pending flag
//    0x4013 r  COIN INPUTS
//    0x4018/9 w  sub->main latch
//    0x401A w  ROM bank   (NOTE: 0x4007 on the older Seibu games -- this
//                          generation moved it, so do not copy that verbatim)
//    0x401B w  coin counters (ignored here, as MiSTer has no coin meter)
//
//  Interrupt arbitration, which the header of seibusound.cpp warns about:
//    int = (rst10_irq & ~rst10_service) | (rst18_irq & ~rst18_service)
//  and on an IM 0 vector fetch, RST18 wins:
//    rst18 pending -> acknowledge, return 0xDF
//    rst10 pending -> acknowledge, return 0xD7
//    neither       -> 0x00 (spurious)
//
//  Note the asymmetry, which is easy to get wrong: acknowledging RST18 CLEARS
//  its request, but acknowledging RST10 does not -- RST10 is driven by the
//  YM2151's level-sensitive IRQ line and only clears when the chip drops it.
//============================================================================

module raiden2_seibu_latch (
    input  logic       clk,
    input  logic       reset,

    // ---- main CPU side (V30), 0x700-0x71F ----------------------------
    input  logic [3:0] main_ofs,     // (addr >> 1) within the window
    input  logic [7:0] main_din,
    input  logic       main_we,      // one-clock strobe
    input  logic       main_rd,
    output logic [7:0] main_dout,

    // ---- Z80 side ----------------------------------------------------
    input  logic [4:0] z80_ofs,      // addr[4:0] within 0x4000-0x401F
    input  logic [7:0] z80_din,
    input  logic       z80_we,       // one-clock strobe
    input  logic       z80_rd,
    output logic [7:0] z80_dout,

    // Coin/start inputs, read by the Z80 at 0x4013. Active low, as the board
    // presents them.
    input  logic [7:0] coin_in,

    // ---- YM2151 interrupt (level) ------------------------------------
    input  logic       ym_irq,

    // ---- to the Z80 --------------------------------------------------
    output logic       z80_int,      // level
    // CONTRACT, and it is load-bearing -- see HANDOFF #65.
    // `z80_intack` MUST be a ONE-CLOCK pulse at the START of the acknowledge,
    // not the raw `~M1_n & ~IORQ_n` level and not that level gated by cen_z80.
    // Acknowledging sets *_service, which drops take18/take10, which changes
    // `z80_vector` below -- so if this input asserts more than once inside a
    // single INTA window the vector collapses to 0x00 *while the Z80 is still
    // sampling the bus*, and the CPU executes a NOP instead of RST 18/RST 10.
    // That silently killed all sound: the handler never runs, so nothing ever
    // clears *_service, so every later interrupt is blocked too.
    input  logic       z80_intack,   // one-clock pulse at IM 0 vector fetch
    // Combinational, and therefore only valid on the cycle of that pulse. The
    // CALLER must hold it for the rest of the acknowledge window
    // (raiden2_sound.sv: z80_vector_stable).
    output logic [7:0] z80_vector,   // 0xDF / 0xD7 / 0x00

    output logic       rom_bank      // 0x401A bit 0
);

    logic [7:0] main2sub [0:1];
    logic [7:0] sub2main [0:1];
    logic       main2sub_pending;
    logic       sub2main_pending;

    logic       rst10_irq, rst10_service;
    logic       rst18_irq, rst18_service;

    // Which vector this acknowledge would take. RST18 has priority.
    wire take18 = rst18_irq & ~rst18_service;
    wire take10 = rst10_irq & ~rst10_service;

    assign z80_int    = take18 | take10;
    assign z80_vector = take18 ? 8'hDF : take10 ? 8'hD7 : 8'h00;

    assign rom_bank = bank_r;
    logic bank_r;

    //------------------------------------------------------------------
    // Read muxes
    //------------------------------------------------------------------
    always_comb begin
        // Unmapped offsets in this window read 0xFF, not 0.
        case (main_ofs)
            4'd2:    main_dout = sub2main[0];
            4'd3:    main_dout = sub2main[1];
            4'd5:    main_dout = {7'd0, main2sub_pending};
            default: main_dout = 8'hFF;
        endcase
    end

    always_comb begin
        case (z80_ofs)
            5'h10:   z80_dout = main2sub[0];
            5'h11:   z80_dout = main2sub[1];
            5'h12:   z80_dout = {7'd0, sub2main_pending};
            5'h13:   z80_dout = coin_in;
            default: z80_dout = 8'hFF;
        endcase
    end

    //------------------------------------------------------------------
    // State
    //------------------------------------------------------------------
    logic ym_irq_d;

    always_ff @(posedge clk) begin
        if (reset) begin
            main2sub[0]      <= 8'd0;
            main2sub[1]      <= 8'd0;
            sub2main[0]      <= 8'd0;
            sub2main[1]      <= 8'd0;
            main2sub_pending <= 1'b0;
            sub2main_pending <= 1'b0;
            rst10_irq        <= 1'b0;
            rst10_service    <= 1'b0;
            rst18_irq        <= 1'b0;
            rst18_service    <= 1'b0;
            bank_r           <= 1'b0;
            ym_irq_d         <= 1'b0;
        end else begin
            ym_irq_d <= ym_irq;

            // The FM interrupt is a LEVEL: it asserts and clears the request
            // directly, unlike RST18 which is a one-shot from the main CPU.
            if (ym_irq & ~ym_irq_d) rst10_irq <= 1'b1;
            if (~ym_irq & ym_irq_d) rst10_irq <= 1'b0;

            //-------------------------------------------------- main side
            if (main_we) begin
                case (main_ofs)
                    4'd0: main2sub[0] <= main_din;
                    4'd1: main2sub[1] <= main_din;
                    4'd4: rst18_irq   <= 1'b1;          // message waiting
                    4'd2, 4'd6: begin
                        sub2main_pending <= 1'b0;
                        main2sub_pending <= 1'b1;
                    end
                    default: ;
                endcase
            end

            //--------------------------------------------------- Z80 side
            if (z80_we) begin
                case (z80_ofs)
                    5'h00: begin                        // pending_w
                        main2sub_pending <= 1'b0;
                        sub2main_pending <= 1'b1;
                    end
                    5'h01: rst18_service <= 1'b0;       // irq_clear_w  (RST18 EOI)
                    5'h02: rst10_service <= 1'b0;       // rst10_ack_w  (RST10 EOI)
                    5'h03: rst18_service <= 1'b0;       // rst18_ack_w  (RST18 EOI)
                    5'h18: sub2main[0]   <= z80_din;
                    5'h19: sub2main[1]   <= z80_din;
                    5'h1A: bank_r        <= z80_din[0];
                    default: ;                          // 0x401B coin counters: no meter here
                endcase
            end

            //------------------------------------------- vector fetch (IM 0)
            // RST18 wins, and acknowledging it also clears the request.
            // RST10 only enters service; its request is owned by the YM.
            if (z80_intack) begin
                if (take18) begin
                    rst18_service <= 1'b1;
                    rst18_irq     <= 1'b0;
                end else if (take10) begin
                    rst10_service <= 1'b1;
                end
            end
        end
    end

endmodule
