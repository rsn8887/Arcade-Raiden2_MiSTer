//============================================================================
//  Filtered work-RAM write streamer -- the successor to the single watchpoint.
//
//  Streams every write to a shortlist of game variables over the HPS UART,
//  with the writing PC. One capture shows the whole state dance: the handler
//  guard (B166), the state byte (9FD2), the frame counter (9FBA), the timer
//  pair (9EC4/9EC6), the critical-section flag (9F62) and the watchdog
//  signature/counter (9D92/9D94).
//
//  Line format:  AAAA=DDDD @PPPPP\r\n   (A=byte addr, D=word written, P=PC;
//  P=CCCCC means the COP wrote it, not the CPU.)
//
//  ~17 bytes/line at 115200 baud = ~650 lines/s. The watched set writes at
//  ~6-10/frame = ~600/s worst case, so a 64-deep FIFO rides the bursts; if it
//  ever overflows the next line is "OVFL" rather than silent loss.
//============================================================================

module raiden2_uart_stream #(
    parameter int CLK_HZ = 64_000_000,
    parameter int BAUD   = 115200,
    // Clocks the handler guard must stay set before the PC range is reported.
    // Overridden small in simulation so the marker path is actually exercised.
    parameter int STUCK_CLKS = 12_000_000,
    // Bit indices, not magnitude compares -- a 24-bit comparator here cost
    // -0.6 ns of hold once. Overridden small in sim so the path is tested.
    parameter int PCS_STUCK_BIT = 20,   // 2^20 clks ~ 16 ms before sampling
    parameter int PCS_DIV_BIT   = 18
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        wr,          // work-RAM write-port strobe
    input  logic [15:0] waddr,       // word address
    input  logic [15:0] wdata,
    input  logic        wcop,        // 1 = COP-sourced
    input  logic [19:0] pc,
    input  logic [15:0] es,          // ES/DS1: the segment `rep stosw` writes through
    input  logic  [2:0] stall_src,   // {cmd_busy, dma_busy, ~rom_ready}
    input  logic        vbl_pulse,   // one clock per vblank, to bound the count

    // Self-test results, 2 bits per check (0 WAIT, 1 BUSY, 2 PASS, 3 FAIL) in
    // the same order as the on-screen page's label list, plus the build stamp.
    // These are rendered to VIDEO ONLY, and this workflow has no framebuffer
    // and no screen capture -- so SOUND Z80 RUNS / OKI ROM FETCH / AUDIO
    // NONZERO / SPRITE PIXELS have been passing or failing invisibly. Streaming
    // them makes the core's own verdict readable without a monitor.
    input  logic [43:0] chk_state,
    input  logic [31:0] build_stamp,

    // #65 discriminator: is ch4 (OKI) starved by the arbiter, or does it never
    // ask? Requests asserted with ready never coming => arbitration (#47).
    // No requests at all => the sound block or the ROM region.
    input  logic        ch4_req,
    input  logic        ch4_rdy,
    // #65 decision table, from raiden2_sound. Streams as FFD2/FFD4/FFD6/FFD8.
    // The OKI fetch path is PROVEN GOOD by `make sound-run`, and `make run`
    // shows the main CPU sending a command every frame, so the break is inside
    // the Z80. These say where.
    input  logic        snd_oki_write,
    input  logic        snd_intack,
    input  logic        snd_latch_rd,
    input  logic        snd_bank_exec,
    // Round 2. The first probe said: ~1 interrupt taken in 100 s, 0 soundlatch
    // reads, 0 execution above 0x8000. So the Z80 is alive but stuck in the
    // low 8 KB. These say WHERE, and how far the RST18 handler gets:
    //   FFDA = the Z80's last M1 (opcode fetch) address -- a live PC sample
    //   FFDC = writes to 0x4003 (rst18_ack). If 0, the handler never acks,
    //          which leaves rst18_service latched and kills every later IRQ.
    //   FFDE = reads of 0x4012 (main_data_pending). The handler polls this
    //          and `BIT 0` gates whether it reads the command at all.
    input  logic [15:0] snd_z80_pc,
    input  logic        snd_rst18_ack,
    input  logic        snd_pending_rd,
    // Live player-1 joystick word, streamed as FFE0. Input had no observability
    // at all, so "no input does anything" could not be told apart from "the
    // pad never reaches the core". Bit numbering follows the CONF_STR list:
    // 0=R 1=L 2=D 3=U 4=Fire 5=Bomb 10=Start 11=Coin 12=Service.
    input  logic [15:0] joy_sample,
    // Tilemap line fills DROPPED because sei0200 was still busy when the next
    // line_start arrived (it only accepts `start` in IDLE). Each drop leaves
    // the previous line's pixels in the buffer, so the background appears to
    // wobble side to side while sprites -- fetched on the higher-priority ch2
    // -- stay steady. Streams as FFE4.
    input  logic [15:0] tm_drop,      // dropped fills in the LAST FRAME (0..282)
    input  logic [15:0] tm_fill_max,  // worst line-fill duration, clk_sys
    // Same pair for the SPRITE engine (sei252), which drops line fills the same
    // silent way and has no per-scanline sprite limit. FFE8 / FFEA.
    input  logic [15:0] spr_drop,
    input  logic [15:0] spr_fill_max,
    // Pause state, so a capture can say whether the game was frozen when the
    // numbers were taken. Streams as FFEC.
    input  logic [15:0] paused,
    // Rotating XOR over all 2048 CRAM entries, recomputed every frame. Streams
    // as FFEE. Compare a frozen good frame against a frozen glitched one.
    input  logic [15:0] cram_hash,
    // #73: COP command triggers PER FRAME. 0x0205 is the object position
    // update the beam's segments ride on. Streams as FFB0 (any) / FFB2 (0205).
    input  logic [15:0] cop_any,
    input  logic [15:0] cop_0205,
    // Coin pulses seen by the sound CPU. Streams as FFCE so a headless
    // capture can say whether an inserted coin actually registered.
    input  logic [15:0] coin_seen,
    // The FIRST unimplemented COP DMA mode / command, latched by raiden2_diag.
    // "COP MODES KNOWN failed" on its own is not actionable -- this says WHICH
    // one to go and implement. It reached the video page only, which is useless
    // in a headless workflow, so it streams as FFD0 = {valid, 000, mode}.
    input  logic  [8:0] unknown_mode,
    input  logic        unknown_valid,

    output logic        txd
);
    localparam int DIV = CLK_HZ / BAUD;

    // Watched WORD addresses (byte addr >> 1).
    function automatic logic watched(input logic [15:0] a);
        // Retargeted at the fade-task far vectors. The fade worker (B18AB,
        // called from the handler full path every frame once 9F4E >= 2) makes
        // an indirect far call through [node+0x4C]; MAME shows the nodes at
        // fixed pool slots 0830/09F0/0BB0 holding A270:F58E / B93F:0D52. If
        // ours holds garbage, the writer PC of that garbage names the culprit.
        // Retargeted 2026-08-06 at the divergence UPSTREAM of the self-link.
        //
        // MAME (tools/nodetrace.lua, 8000 frames) constructs and inserts node
        // 0830 exactly ONCE, on frame 36, and never touches it again. Ours
        // does it twice, and the second insert self-links because the list
        // head still holds 0830. But the second insert is a consequence: our
        // core also writes 9F4E from 98A75 / 98AAD / 9AAB3 / 9AB9E, four sites
        // MAME never executes at all. MAME arms its second fade on frame 86
        // and leaves 9F4E = 0002 pending for the whole run; ours clears it and
        // walks on into the next attract stage, which respawns the fade task.
        //
        // So the question is no longer "why do we insert twice" but "why do we
        // leave a state MAME stays in". These are the variables that answer it:
        //
        //   9D20  head slot for node 0830's list -- shows insert AND removal,
        //         so we can see whether anything ever unlinks it (MAME: no)
        //   9FBA  the per-vblank frame counter, so our frame numbers line up
        //         with MAME's trace line for line
        //   9F4E  fade mode: who arms it, who clears it, and on which frame
        //
        // The other three nodes' far vectors are dropped: they never differed,
        // and the UART is 115200 baud.
        watched = (a == 16'h58B3)    // B166 handler guard
               || (a == 16'h4FA7)    // 9F4E fade mode
               || (a == 16'h4E90)    // 9D20 list head for node 0830  <- NEW
               || (a == 16'h043C)    // 0878 node 0830 ->next; non-zero = wedge
               || (a == 16'h043E)    // 087C/087E vec of node 0830 (constructor)
               || (a == 16'h043F);
    endfunction

    // ---- self-test line emitter -----------------------------------------
    // Five lines, emitted when the results change and then once every ~2 s so a
    // capture taken at any moment carries them:
    //   FFC0=<chk[15:0]>  FFC2=<chk[31:16]>  FFC4=<chk[43:32]>
    //   FFC6=<stamp lo>   FFC8=<stamp hi>
    logic  [4:0] self_req;   // 16..1, one line each
    logic [43:0] chk_d;
    logic [26:0] self_tmr;
    always_ff @(posedge clk) begin
        if (reset) begin
            self_req <= 5'd0; chk_d <= 44'd0; self_tmr <= 27'd0;
        end else begin
            chk_d    <= chk_state;
            self_tmr <= self_tmr + 27'd1;
            if (chk_state != chk_d || self_tmr == 27'd0) self_req <= 5'd26;
            else if (self_take && self_req != 0) self_req <= self_req - 5'd1;
        end
    end

    // Saturating so a wrapped counter cannot read as "few requests".
    logic [15:0] ch4_req_cnt, ch4_rdy_cnt;
    logic        ch4_req_d, ch4_rdy_d;
    always_ff @(posedge clk) begin
        if (reset) begin
            ch4_req_cnt <= 16'd0; ch4_rdy_cnt <= 16'd0;
            ch4_req_d <= 1'b0; ch4_rdy_d <= 1'b0;
        end else begin
            ch4_req_d <= ch4_req; ch4_rdy_d <= ch4_rdy;
            if (ch4_req && !ch4_req_d && !(&ch4_req_cnt)) ch4_req_cnt <= ch4_req_cnt + 16'd1;
            if (ch4_rdy && !ch4_rdy_d && !(&ch4_rdy_cnt)) ch4_rdy_cnt <= ch4_rdy_cnt + 16'd1;
        end
    end

    // #65 decision table. These are already one-cen_z80 strobes, so they are
    // counted directly rather than edge-detected -- an edge detector would
    // merge two back-to-back writes into one.
    logic [15:0] oki_w_cnt, intack_cnt, latch_rd_cnt, bank_ex_cnt;
    always_ff @(posedge clk) begin
        if (reset) begin
            oki_w_cnt <= 16'd0; intack_cnt   <= 16'd0;
            latch_rd_cnt <= 16'd0; bank_ex_cnt <= 16'd0;
        end else begin
            if (snd_oki_write && !(&oki_w_cnt))    oki_w_cnt    <= oki_w_cnt    + 16'd1;
            if (snd_intack    && !(&intack_cnt))   intack_cnt   <= intack_cnt   + 16'd1;
            if (snd_latch_rd  && !(&latch_rd_cnt)) latch_rd_cnt <= latch_rd_cnt + 16'd1;
            if (snd_bank_exec && !(&bank_ex_cnt))  bank_ex_cnt  <= bank_ex_cnt  + 16'd1;
        end
    end

    // STICKY joystick witness. The live FFE0 sample is only emitted once per
    // ~2 s rotation, so a button press can fall entirely between samples and
    // read as "no input ever arrived" -- the same field-of-view trap as the
    // BADC marker and the 90 s self-test window. This latches every bit that
    // has EVER been high since reset, so a single press at any moment in the
    // run is still visible in a capture taken later. Streams as FFE2.
    logic [15:0] joy_sticky;
    always_ff @(posedge clk)
        if (reset) joy_sticky <= 16'd0;
        else       joy_sticky <= joy_sticky | joy_sample;

    logic [15:0] rst18ack_cnt, pendrd_cnt;
    always_ff @(posedge clk) begin
        if (reset) begin
            rst18ack_cnt <= 16'd0; pendrd_cnt <= 16'd0;
        end else begin
            if (snd_rst18_ack  && !(&rst18ack_cnt)) rst18ack_cnt <= rst18ack_cnt + 16'd1;
            if (snd_pending_rd && !(&pendrd_cnt))   pendrd_cnt   <= pendrd_cnt   + 16'd1;
        end
    end

    logic [15:0] self_addr, self_data;
    always_comb begin
        case (self_req)
            5'd9: begin self_addr = 16'h7FE0; self_data = chk_state[15:0];       end
            5'd8: begin self_addr = 16'h7FE1; self_data = chk_state[31:16];      end
            5'd7: begin self_addr = 16'h7FE2; self_data = {4'd0, chk_state[43:32]}; end
            5'd6: begin self_addr = 16'h7FE4; self_data = build_stamp[31:16];     end
            5'd5: begin self_addr = 16'h7FE3; self_data = build_stamp[15:0];     end
            5'd4: begin self_addr = 16'h7FE5; self_data = ch4_req_cnt;           end
            5'd3: begin self_addr = 16'h7FE6; self_data = ch4_rdy_cnt;           end
            5'd1: begin self_addr = 16'h7FE7; self_data = coin_seen;             end
            // #65 decision table -> FFD2 / FFD4 / FFD6 / FFD8
            5'd13: begin self_addr = 16'h7FE9; self_data = oki_w_cnt;            end
            5'd12: begin self_addr = 16'h7FEA; self_data = intack_cnt;           end
            5'd11: begin self_addr = 16'h7FEB; self_data = latch_rd_cnt;         end
            5'd10: begin self_addr = 16'h7FEC; self_data = bank_ex_cnt;          end
            // round 2 -> FFDA / FFDC / FFDE
            5'd16: begin self_addr = 16'h7FED; self_data = snd_z80_pc;           end
            5'd15: begin self_addr = 16'h7FEE; self_data = rst18ack_cnt;         end
            5'd14: begin self_addr = 16'h7FEF; self_data = pendrd_cnt;           end
            5'd17: begin self_addr = 16'h7FF0; self_data = joy_sample;          end
            5'd18: begin self_addr = 16'h7FF1; self_data = joy_sticky;          end
            5'd19: begin self_addr = 16'h7FF2; self_data = tm_drop;             end
            5'd20: begin self_addr = 16'h7FF3; self_data = tm_fill_max;         end
            5'd21: begin self_addr = 16'h7FF4; self_data = spr_drop;            end
            5'd22: begin self_addr = 16'h7FF5; self_data = spr_fill_max;        end
            5'd23: begin self_addr = 16'h7FF6; self_data = paused;              end
            5'd24: begin self_addr = 16'h7FF7; self_data = cram_hash;           end
            5'd25: begin self_addr = 16'h7FD8; self_data = cop_any;             end
            5'd26: begin self_addr = 16'h7FD9; self_data = cop_0205;            end
            default: begin self_addr = 16'h7FE8;
                           self_data = {unknown_valid, 6'd0, unknown_mode};       end
        endcase
    end

    // ---- capture FIFO ----------------------------------------------------
    logic [51:0] fifo [0:63];        // {addr16, data16, pc20}
    logic  [5:0] wp, rp;
    logic  [6:0] cnt;
    logic        ovfl;

    // Edge-qualified: the work-RAM write enable is a LEVEL held for several
    // clocks per bus write, and enqueuing on the level dumped duplicates.
    logic wr_d;
    always_ff @(posedge clk) wr_d <= wr && watched(waddr);
    wire hit = wr && watched(waddr) && !wr_d;

    // PC bounds trap. Program code lives at linear 0x40000+; a fetch below
    // that means the CPU is executing RAM -- the signature of an indirect call
    // through a garbage pointer, which is exactly how the fade worker is
    // suspected of dying. One-shot: latches the first offender and enqueues a
    // marker line  BADC=<bad pc low16> @<last good pc>  naming who jumped.
    logic        trapped, trap_req;
    logic [19:0] trap_from;
    logic [15:0] trap_badpc;
    always_ff @(posedge clk) begin
        if (reset) begin
            trapped <= 0; trap_req <= 0; trap_from <= 0;
        end else begin
            if (pc >= 20'h40000) trap_from <= pc;
            else if (!trapped && trap_from != 0) begin
                trapped    <= 1'b1;
                trap_req   <= 1'b1;
                trap_badpc <= pc[15:0];
            end
            if (trap_req && !hit && cnt != 7'd64) trap_req <= 1'b0;
        end
    end

    // ---- in-handler PC range ------------------------------------------
    // Every probe so far has watched DATA and come back "correct". This
    // watches CONTROL FLOW: while the handler guard at B166 is set, bracket
    // every PC executed. On a healthy frame the guard clears and the range is
    // discarded. When the guard sticks -- the wedge -- the accumulated
    // low/high bracket names the routine the handler is spinning in, and its
    // disassembly names the hardware read it is waiting on.
    //
    // Reported as two marker lines once ~2s of stuck guard has passed:
    //   FFF0=<low16>  @<low20>   (PC range LOW)
    //   FFF2=<high16> @<high20>  (PC range HIGH)
    // The IDs render shifted because the formatter converts word->byte.
    logic        guard;                    // mirrors 0xB166 != 0
    logic [19:0] hpc_lo, hpc_hi;
    logic [23:0] stuck_cnt;
    logic  [1:0] rng_req;                  // 2 = emit LO, 1 = emit HI
    logic        dur_req;                  // emit a handler-duration marker
    logic [15:0] dur_val;

    wire guard_wr = wr && (waddr == 16'h58B3) && !wr_d;

    // ---- full-path entries per frame ----------------------------------
    // The fade wedges because a list node is inserted twice (MAME: once). The
    // handler's full path is what performs that insert, and it finishes in
    // ~1.6% of a frame, so nothing stops it running twice if two interrupts
    // arrive. Report the count each frame:  FFFA=000<n> @<pc>
    logic [3:0] fp_cnt;
    logic       fp_req;
    logic [3:0] fp_val;
    always_ff @(posedge clk) begin
        if (reset) begin
            fp_cnt <= 0; fp_req <= 0;
        end else begin
            if (guard_wr && wdata != 16'd0 && fp_cnt != 4'hF)
                fp_cnt <= fp_cnt + 4'd1;
            if (vbl_pulse) begin
                fp_val <= fp_cnt;
                fp_req <= 1'b1;
                fp_cnt <= 4'd0;
            end
            if (fp_req && !hit && cnt != 7'd64) fp_req <= 1'b0;
        end
    end

    // ---- node-pool init entry counter (FFEE) ---------------------------
    //
    // 0xB17F4 is the node-pool init. Its body is
    //     b1800: mov di,0x82c / mov cx,0x9d8c / sub cx,di / shr cx,1
    //     b180a: rep stos WORD PTR es:[di],ax
    // which zeroes 0x82C..0x9D8B -- covering node 0830's fields AND all
    // seventeen task-list heads at 9D1E-9D3E.
    //
    // MAME runs this TWICE: at boot and again on frame 1230, and its second
    // run is what makes the second insert of node 0830 safe (old head 0). Our
    // core produces work-RAM writes from it only once (#53), and the code path
    // to it is unconditional straight-line (#51) -- which should be impossible.
    //
    // Two very different faults produce that one symptom, and this counter
    // separates them:
    //   count == 2  the routine RUNS both times, so the fill is going
    //               somewhere else -- `rep stosw` writes through ES:[DI], so
    //               suspect a wrong/clobbered ES, or a REP aborted by the
    //               interrupt that is enabled on the second pass but not the
    //               first.
    //   count == 1  the routine is genuinely never entered, so control flow
    //               diverges upstream and the disassembly-based reasoning in
    //               #51 is missing a path.
    //
    // Counted on entry to the routine, edge-detected, and reported only when
    // it changes -- one extra UART line per run, not per frame.
    logic [3:0] pool_cnt;
    logic       pool_req, pool_in_d;
    logic [15:0] pool_es;
    wire        pool_in = (pc >= 20'hB17F4) && (pc <= 20'hB1810);
    always_ff @(posedge clk) begin
        if (reset) begin
            pool_cnt <= 0; pool_req <= 0; pool_in_d <= 0; pool_es <= 0;
        end else begin
            pool_in_d <= pool_in;
            if (pool_in && !pool_in_d && pool_cnt != 4'hF) begin
                pool_cnt <= pool_cnt + 4'd1;
                pool_es  <= es;          // ES at entry -- the fill's destination
                pool_req <= 1'b1;
            end
            if (pool_req && !hit && cnt != 7'd64) pool_req <= 1'b0;
        end
    end

    // ---- CPU stall detector -------------------------------------------
    // cpu_run = cpu_ce & rom_ready & ~dma_busy & ~cmd_busy. A handler call
    // that never returns is equally consistent with a software loop and with
    // the CPU simply being held off the bus, and the two need completely
    // different fixes. This separates them: if any gate stays asserted for
    // longer than a scanline could justify, report which one, and where.
    //
    //   FFF6=000<src> @<pc>    src bit0 !rom_ready, bit1 dma_busy, bit2 cmd_busy
    //
    // Threshold is a single bit test, not a magnitude compare -- the 24-bit
    // comparator in the earlier bracket cost -0.6 ns of hold and survived two
    // reseeds. Bit 15 is 32768 clocks = 512 us at 64 MHz, which no legitimate
    // COP operation or SDRAM fetch comes close to.
    logic [15:0] stall_cnt;
    logic        stall_req, stall_seen;
    logic  [2:0] stall_val;
    always_ff @(posedge clk) begin
        if (reset) begin
            stall_cnt <= 0; stall_req <= 0; stall_seen <= 0;
        end else begin
            if (stall_src == 3'd0) begin
                stall_cnt  <= 16'd0;
                stall_seen <= 1'b0;          // rearm once the CPU moves again
            end else if (!stall_cnt[15]) begin
                stall_cnt <= stall_cnt + 16'd1;
            end else if (!stall_seen) begin
                stall_seen <= 1'b1;          // one marker per stall episode
                stall_req  <= 1'b1;
                stall_val  <= stall_src;
            end
            if (stall_req && !hit && cnt != 7'd64) stall_req <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            guard <= 0; stuck_cnt <= 0; rng_req <= 0;
            hpc_lo <= 20'hFFFFF; hpc_hi <= 0;
        end else begin
            if (guard_wr) begin
                guard <= (wdata != 16'd0);
                if (wdata != 16'd0) begin       // entering the handler
                    hpc_lo <= 20'hFFFFF; hpc_hi <= 0; stuck_cnt <= 0;
                end else begin
                    // Guard cleared: the handler completed. Report how long it
                    // took. MAME never nests, so on real hardware this is
                    // always well under one frame (1,066,666 clocks at 64 MHz).
                    // If our fade frame approaches that, a vblank nests into a
                    // handler the game never expects to be re-entered, and the
                    // problem is throughput rather than logic.
                    dur_val <= stuck_cnt[23:8];   // units of 256 clocks
                    dur_req <= 1'b1;
                    stuck_cnt <= 0;
                end
            end
            if (guard) begin
                // Only bracket the FIRST ~1.5 frames after the guard sets.
                // Beyond that the main thread's spin and the minimal interrupt
                // path pollute the range -- the first attempt spanned 110 KB
                // and isolated nothing. The handler's own fatal pass is inside
                // this window by definition, since a healthy pass clears the
                // guard within one frame.
                // Single bit test, not a 24-bit magnitude compare: the
                // comparator version cost -0.6 ns of hold and two reseeds
                // failed to place it. Bit 21 sets at 2^21 clocks = 32.8 ms
                // ~ 2 frames, which is the window we want anyway.
                // ~1 ms (2^16 clocks), not 2 frames. At 2 frames the range
                // still spanned 110 KB, which proved the handler does NOT spin
                // -- it escapes without clearing the guard and normal code
                // keeps running. 1 ms captures the handler's own pass before
                // the next vblank can nest into it.
                if (!stuck_cnt[16]) begin
                    if (pc < hpc_lo) hpc_lo <= pc;
                    if (pc > hpc_hi) hpc_hi <= pc;
                end
                if (stuck_cnt != 24'hFFFFFF) stuck_cnt <= stuck_cnt + 24'd1;
                // ~2 s at 64 MHz -- far beyond any legitimate handler pass
                if (stuck_cnt == STUCK_CLKS[23:0]) rng_req <= 2'd2;
            end
            if (rng_req != 0 && !hit && !trap_req && cnt != 7'd64)
                rng_req <= rng_req - 2'd1;
            if (dur_req && !hit && !trap_req && rng_req == 0 && cnt != 7'd64)
                dur_req <= 1'b0;
        end
    end

    wire        trap_take = trap_req && !hit;
    wire        rng_take  = (rng_req != 0) && !hit && !trap_req;
    wire        dur_take  = dur_req && !hit && !trap_req && (rng_req == 0);
    wire        stall_take = stall_req && !hit && !trap_req && (rng_req == 0)
                             && !dur_req;
    wire        fp_take   = fp_req && !hit && !trap_req && (rng_req == 0)
                            && !dur_req && !stall_req;
    wire        pool_take = pool_req && !hit && !trap_req && (rng_req == 0)
                            && !dur_req && !stall_req && !fp_req;
    wire        self_take = (self_req != 5'd0) && !hit && !trap_req
                            && (rng_req == 0) && !dur_req && !stall_req
                            && !fp_req && !pool_req && cnt < 7'd56;
    wire        push      = hit || trap_take || rng_take || dur_take || stall_take
                            || fp_take || pool_take || self_take;
    wire [51:0] wentry    = hit      ? {waddr, wdata, wcop ? 20'hCCCCC : pc}
                          : trap_take ? {16'hBADC, trap_badpc, trap_from}
                          : rng_take ? ((rng_req == 2'd2)
                                          ? {16'h7FF8, hpc_lo[15:0], hpc_lo}
                                          : {16'h7FF9, hpc_hi[15:0], hpc_hi})
                          // FFF4=<duration/256>  -- handler pass length
                          : dur_take ? {16'h7FFA, dur_val, 20'd0}
                          // FFF6=<stall source> @<pc>  -- who is holding the CPU
                          : stall_take ? {16'h7FFB, 13'd0, stall_val, pc}
                          // FFF8=<pc>  -- where the stuck handler is looping
                          // FFFA=<n> -- handler full-path entries this frame
                          : fp_take ? {16'h7FFD, 12'd0, fp_val, 20'd0}
                          // FFEE=<n> -- times the node-pool init at B17F4 ran
                          : pool_take ? {16'h7FF7, pool_es, pc}
                          // FFC0..FFC8 -- self-test results + build stamp
                                     : {self_addr, self_data, 20'd0};
    wire pop;

    always_ff @(posedge clk) begin
        if (reset) begin
            wp <= 0; rp <= 0; cnt <= 0; ovfl <= 0;
        end else begin
            case ({push && cnt != 7'd64, pop && cnt != 0})
                2'b10: begin
                    fifo[wp] <= wentry;
                    wp <= wp + 6'd1; cnt <= cnt + 7'd1;
                end
                2'b01: begin rp <= rp + 6'd1; cnt <= cnt - 7'd1; end
                2'b11: begin
                    fifo[wp] <= wentry;
                    wp <= wp + 6'd1; rp <= rp + 6'd1;
                end
                default: ;
            endcase
            if (push && cnt == 7'd64) ovfl <= 1'b1;
            if (pop && cnt == 0) ;                    // cannot happen: pop gated
            if (ovfl && cnt == 0) ovfl <= 1'b0;       // report once drained
        end
    end

    wire [51:0] head = fifo[rp];
    wire [15:0] h_addr = head[51:36];
    wire [15:0] h_data = head[35:20];
    wire [19:0] h_pc   = head[19:0];
    // Display the BYTE address (word addr << 1) -- matches every note so far.
    //
    // This DROPS bit 15. For real work-RAM addresses that is harmless (they
    // are all < 0x8000), and the synthetic 0x7FFx markers are chosen to render
    // as 0xFFFx. But the trap marker 0xBADC has bit 15 SET, so it printed as
    // 0x75B8 and did not name itself -- `grep BADC` found nothing while the
    // trap was firing on every run. Cost an hour on 2026-08-07 (#61). Markers
    // whose byte rendering must be exact bypass the shift.
    wire [15:0] h_byte = h_addr[15] ? h_addr : {h_addr[14:0], 1'b0};

    function automatic [7:0] hx(input [3:0] v);
        hx = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h41 + {4'd0, v} - 8'd10);
    endfunction

    // ---- line formatter --------------------------------------------------
    localparam int LINE_LEN = 18;      // AAAA=DDDD @PPPPP\r\n
    logic [4:0] idx;
    logic       sending, send_ovfl;

    logic [7:0] ch;
    always_comb begin
        if (send_ovfl) begin
            case (idx)
                5'd0: ch = "O"; 5'd1: ch = "V"; 5'd2: ch = "F"; 5'd3: ch = "L";
                5'd4: ch = 8'h0D; default: ch = 8'h0A;
            endcase
        end else begin
            case (idx)
                5'd0:  ch = hx(h_byte[15:12]);
                5'd1:  ch = hx(h_byte[11:8]);
                5'd2:  ch = hx(h_byte[7:4]);
                5'd3:  ch = hx(h_byte[3:0]);
                5'd4:  ch = "=";
                5'd5:  ch = hx(h_data[15:12]);
                5'd6:  ch = hx(h_data[11:8]);
                5'd7:  ch = hx(h_data[7:4]);
                5'd8:  ch = hx(h_data[3:0]);
                5'd9:  ch = " ";
                5'd10: ch = "@";
                5'd11: ch = hx(h_pc[19:16]);
                5'd12: ch = hx(h_pc[15:12]);
                5'd13: ch = hx(h_pc[11:8]);
                5'd14: ch = hx(h_pc[7:4]);
                5'd15: ch = hx(h_pc[3:0]);
                5'd16: ch = 8'h0D;
                default: ch = 8'h0A;
            endcase
        end
    end
    wire [4:0] line_last = send_ovfl ? 5'd5 : 5'd17;

    // ---- 8N1 transmitter -------------------------------------------------
    logic [15:0] baud_cnt;
    logic  [3:0] bit_idx;
    logic  [9:0] shifter;
    logic        busy;

    // The entry is consumed as its line FINISHES, so `head` stays stable for
    // the whole transmission.
    logic do_pop_r;
    assign pop = do_pop_r;

    always_ff @(posedge clk) begin
        do_pop_r <= 1'b0;
        if (reset) begin
            txd <= 1'b1; busy <= 0; sending <= 0; send_ovfl <= 0;
            idx <= 0; baud_cnt <= 0; bit_idx <= 0;
        end else begin
            if (!sending) begin
                if (ovfl) begin
                    send_ovfl <= 1'b1; sending <= 1'b1; idx <= 0;
                end else if (cnt != 0 && !do_pop_r) begin
                    // do_pop_r means the count still includes the entry whose
                    // line JUST finished -- starting now would send a ghost
                    // line from an empty slot. Proven in sim: every real line
                    // was followed by "0000=0000 @00000" without this guard.
                    send_ovfl <= 1'b0; sending <= 1'b1; idx <= 0;
                end
            end

            if (!busy) begin
                if (sending) begin
                    shifter  <= {1'b1, ch, 1'b0};
                    bit_idx  <= 0;
                    baud_cnt <= DIV[15:0] - 16'd1;
                    busy     <= 1'b1;
                    txd      <= 1'b0;
                end
            end else if (baud_cnt != 0) begin
                baud_cnt <= baud_cnt - 16'd1;
            end else begin
                baud_cnt <= DIV[15:0] - 16'd1;
                shifter  <= {1'b1, shifter[9:1]};
                txd      <= shifter[1];
                if (bit_idx == 4'd9) begin
                    busy <= 0; txd <= 1'b1;
                    if (idx == line_last) begin
                        sending <= 1'b0;
                        if (!send_ovfl) do_pop_r <= 1'b1;   // consume the entry
                    end else begin
                        idx <= idx + 5'd1;
                    end
                end else begin
                    bit_idx <= bit_idx + 4'd1;
                end
            end
        end
    end

endmodule
