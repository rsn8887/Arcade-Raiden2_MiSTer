//============================================================================
//  Raiden II - COP sprite protection / display-list builder
//
//  Ground truth: MAME src/mame/seibu/raiden2.cpp, xsedae_state::
//  sprite_prot_*  (LGPL-2.1+, Olivier Galibert, Angelo Salese, David Haywood).
//  raiden2_cop_mem() -> xsedae_cop_mem() maps all of these for raiden2.
//
//      0x6C0/1  spr_off      r/w   offset within the record to head1/head2
//      0x6C2/3  src_seg      r/w   source segment
//      0x6C4/5  --                 constant, nopw in MAME
//      0x6C6/7  dst1         w     display-list write pointer
//      0x6CE/F  flags_2      w     latched, unused by raiden2
//      0x6D8/9  prot_x       w     camera X
//      0x6DA/B  prot_y       w     camera Y
//      0x6DC/D  maxx         r/w   right clip edge
//      0x6DE/F  src_off      w     source offset -- WRITING THIS RUNS IT
//      0x762/3  dst1         r     read back after the COP has advanced it
//
//  MAME's engine, verbatim:
//
//      src   = (src_seg << 4) + src_off
//      x     = int16(read_dword(src+0x08) >> 16) - prot_x)   // word at src+0x0A
//      y     = int16(read_dword(src+0x04) >> 16) - prot_y)   // word at src+0x06
//      head1 = word[src + spr_off];  head2 = word[src + spr_off + 2]
//      w     = (((head1 >>  8) & 7) + 1) << 4                // 16..128
//      h     = (((head1 >> 12) & 7) + 1) << 4
//      flag  = (x-w/2 > -w) && (x-w/2 < maxx+w) &&
//              (y-h/2 > -h) && (y-h/2 < 256+h)
//      word[src] = (word[src] & 0xFFFE) | flag
//      if (flag) { word[dst1+0]=head1; word[dst1+2]=head2;
//                  word[dst1+4]=x-w/2; word[dst1+6]=y-h/2; dst1 += 8; }
//
//  WHY THIS BLOCK EXISTS AT ALL (HANDOFF #61): 0x762 was decoded and routed out
//  of raiden2_main but never driven, so it read 0x0000 and the game's builder
//  at 0xA4468 wrote its 8-byte records from address 0 -- over interrupt vector
//  0x30 at byte 0xC0. That killed the attract sequence. Latching dst1 fixed the
//  crash; this module implements the rest of the block so the display list is
//  actually built rather than merely not-fatal.
//
//  Bus model: a work-RAM master like raiden2_cop_dma, holding the CPU off the
//  bus with `busy` for the handful of cycles a record takes. Real COP latency
//  has never been measured; MAME does the whole thing instantaneously.
//============================================================================

module raiden2_sprprot (
    input  logic        clk,
    input  logic        reset,

    // Register window writes. reg_addr is addr[10:0], reg_we a 1-clock strobe.
    input  logic [10:0] reg_addr,
    input  logic [15:0] reg_data,
    input  logic        reg_we,

    // Work RAM master port. Read latency must match the RAM (2 clocks).
    output logic [15:0] ram_addr,     // WORD address
    input  logic [15:0] ram_data,
    output logic [15:0] ram_wdata,
    output logic        ram_we,

    // Readable registers
    output logic [15:0] dst1,         // 0x762 readback
    output logic [15:0] spr_off,      // 0x6C0 readback
    output logic [15:0] src_seg,      // 0x6C2 readback
    output logic [15:0] maxx,         // 0x6DC readback

    output logic        busy          // hold the CPU off the bus while high
);

    logic [15:0] flags_2, prot_x, prot_y, src_off;

    // Byte address of the record; word address is src_byte[16:1].
    logic [19:0] src_byte;
    wire  [15:0] src_word = src_byte[16:1];

    // dst1 and spr_off are 16-bit BYTE quantities, so their word forms are
    // [15:1] zero-extended -- NOT [16:1], which is out of range and was caught
    // by SELRANGE on the first build. Same width class as #25.
    wire [15:0] dst1_word    = {1'b0, dst1[15:1]};
    wire [15:0] spr_off_word = {1'b0, spr_off[15:1]};

    logic [15:0] head1, head2, flag_old;
    logic signed [17:0] xs, ys;       // wider than 16 so x-w/2 cannot wrap
    logic signed [17:0] wv, hv;

    // MAME computes in `int`: x/y are int16 promoted, w/h are small positives.
    wire signed [17:0] xw = xs - (wv >>> 1);
    wire signed [17:0] yh = ys - (hv >>> 1);
    wire on_screen = (xw >  -wv)
                  && (xw <  $signed({2'b00, maxx}) + wv)
                  && (yh >  -hv)
                  && (yh <  18'sd256 + hv);

    typedef enum logic [4:0] {
        IDLE,
        RD_X_A,  RD_X_B,  RD_X_L,     // word[src+0x0A]
        RD_Y_A,  RD_Y_B,  RD_Y_L,     // word[src+0x06]
        RD_H1_A, RD_H1_B, RD_H1_L,    // word[src+spr_off]
        RD_H2_A, RD_H2_B, RD_H2_L,    // word[src+spr_off+2]
        RD_FL_A, RD_FL_B, RD_FL_L,    // word[src]
        WR_FLAG,
        WR_D0, WR_D1, WR_D2, WR_D3,
        DONE
    } state_e;
    state_e state;

    // WORK RAM READ TIMING -- the thing that broke this module first time round.
    //
    // singleport_ram is a TWO-STAGE pipeline (q_stage1 -> q_stage2), so an
    // address on the bus during cycle N is readable during cycle N+2. The
    // first version REGISTERED ram_addr and then latched after a single wait
    // state, so every read returned the PREVIOUS address's data: stale head1
    // and x/y put the flag write at the wrong address and destroyed the stack
    // (sim PC-OOB, bad_pc=00C8F, SP=0016).
    //
    // Fix: drive ram_addr / ram_we / ram_wdata COMBINATIONALLY from the state,
    // exactly as raiden2_cop_dma does, and hold each read address stable for
    // its three states so the data is valid in the third.
    always_comb begin
        ram_addr  = src_word;
        ram_we    = 1'b0;
        ram_wdata = 16'd0;
        unique case (state)
            RD_X_A,  RD_X_B,  RD_X_L:  ram_addr = src_word + 16'd5;
            RD_Y_A,  RD_Y_B,  RD_Y_L:  ram_addr = src_word + 16'd3;
            RD_H1_A, RD_H1_B, RD_H1_L: ram_addr = src_word + spr_off_word;
            RD_H2_A, RD_H2_B, RD_H2_L: ram_addr = src_word + spr_off_word + 16'd1;
            RD_FL_A, RD_FL_B, RD_FL_L: ram_addr = src_word;
            WR_FLAG: begin ram_addr = src_word;
                           ram_wdata = {flag_old[15:1], on_screen}; ram_we = 1'b1; end
            WR_D0:   begin ram_addr = dst1_word;         ram_wdata = head1;    ram_we = 1'b1; end
            WR_D1:   begin ram_addr = dst1_word + 16'd1; ram_wdata = head2;    ram_we = 1'b1; end
            WR_D2:   begin ram_addr = dst1_word + 16'd2; ram_wdata = xw[15:0]; ram_we = 1'b1; end
            WR_D3:   begin ram_addr = dst1_word + 16'd3; ram_wdata = yh[15:0]; ram_we = 1'b1; end
            IDLE, DONE: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state   <= IDLE;
            dst1    <= 16'd0;  spr_off <= 16'd0;  src_seg <= 16'd0;
            maxx    <= 16'd0;  flags_2 <= 16'd0;
            prot_x  <= 16'd0;  prot_y  <= 16'd0;  src_off <= 16'd0;
            src_byte<= 20'd0;  busy    <= 1'b0;
        end else begin
            unique case (state)
            IDLE: begin
                busy <= 1'b0;
                if (reg_we) begin
                    case (reg_addr)
                        11'h6c0: spr_off <= reg_data;
                        11'h6c2: src_seg <= reg_data;
                        11'h6c6: dst1    <= reg_data;
                        11'h6ce: flags_2 <= reg_data;
                        11'h6d8: prot_x  <= reg_data;
                        11'h6da: prot_y  <= reg_data;
                        11'h6dc: maxx    <= reg_data;
                        11'h6de: begin   // writing src_off RUNS the engine
                            src_off  <= reg_data;
                            src_byte <= {src_seg, 4'd0} + {4'd0, reg_data};
                            busy     <= 1'b1;
                            state    <= RD_X_A;
                        end
                        default: ;
                    endcase
                end
            end
            RD_X_A:  state <= RD_X_B;
            RD_X_B:  state <= RD_X_L;
            RD_X_L:  begin
                        xs <= $signed({{2{ram_data[15]}}, ram_data})
                            - $signed({{2{prot_x[15]}},  prot_x});
                        state <= RD_Y_A;
                     end
            RD_Y_A:  state <= RD_Y_B;
            RD_Y_B:  state <= RD_Y_L;
            RD_Y_L:  begin
                        ys <= $signed({{2{ram_data[15]}}, ram_data})
                            - $signed({{2{prot_y[15]}},  prot_y});
                        state <= RD_H1_A;
                     end
            RD_H1_A: state <= RD_H1_B;
            RD_H1_B: state <= RD_H1_L;
            RD_H1_L: begin
                        head1 <= ram_data;
                        wv <= 18'sd16 * (18'sd1 + $signed({15'd0, ram_data[10:8]}));
                        hv <= 18'sd16 * (18'sd1 + $signed({15'd0, ram_data[14:12]}));
                        state <= RD_H2_A;
                     end
            RD_H2_A: state <= RD_H2_B;
            RD_H2_B: state <= RD_H2_L;
            RD_H2_L: begin head2 <= ram_data; state <= RD_FL_A; end
            RD_FL_A: state <= RD_FL_B;
            RD_FL_B: state <= RD_FL_L;
            RD_FL_L: begin flag_old <= ram_data; state <= WR_FLAG; end
            WR_FLAG: state <= on_screen ? WR_D0 : DONE;
            WR_D0:   state <= WR_D1;
            WR_D1:   state <= WR_D2;
            WR_D2:   state <= WR_D3;
            WR_D3:   begin dst1 <= dst1 + 16'd8; state <= DONE; end
            DONE:    begin busy <= 1'b0; state <= IDLE; end
            endcase
        end
    end
endmodule
