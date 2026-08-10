//============================================================================
//  Raiden II - Seibu COP (SEI1000) command engine
//
//  The half of the COP that is not DMA. The CPU points the COP at object
//  structures in work RAM via eight 32-bit pointer registers, then writes a
//  trigger value to 0x500; the COP walks those structures and writes results
//  back. Without it every result register reads 0, the game computes nothing,
//  and it clears the sprite list each frame without ever filling it -- which is
//  exactly what a trace of the running CPU shows.
//
//  Ground truth: MAME src/mame/seibu/seibucop.cpp + seibucop_cmd.ipp
//  (LGPL-2.1+, Olivier Galibert, Angelo Salese, David Haywood, Tomasz Slanina).
//
//  IMPORTANT -- what MAME's COP actually is:
//
//  MAME is a high-level SIMULATION. `cop_cmd_w` switches on the raw trigger
//  value written to 0x500 and calls hand-written C. The 32x8 table of 11-bit
//  micro-ops that the game uploads is parsed only by a debug disassembler; its
//  ISA has never been executed by anything. `find_trigger_match()` is called
//  but its result is discarded -- it exists to log which triggers a game uses.
//
//  So this module does the same thing: decode the trigger, run a fixed
//  sequence. That is a faithful port of the only known-working implementation,
//  not silicon accuracy. We still capture the uploaded macro table (below),
//  because it is the one artefact that could eventually support a real
//  micro-coded implementation, and because it lets us assert that this game
//  uploads the program we think it does.
//
//  Register map (offsets within the 0x400-0x7FF window):
//    0x432/0x434        macro program data / address
//    0x438/0x43A/0x43C  per-slot value / mask / trigger
//    0x4A0-0x4AD        cop_regs[0..6] high word   (r/w)
//    0x4C0-0x4CD        cop_regs[0..6] low word    (r/w)
//    0x500-0x505        command trigger; offset 0..2 selects the sub-object
//    0x580-0x589        collision results
//    0x5B0/0x5B2/0x5B4  status / distance / angle
//
//  Note MAME maps only SEVEN of the eight pointer registers (0x4A0-0x4AD is
//  14 bytes). cop_regs[7] exists but is not addressable; that is the hardware's
//  map, not an oversight here.
//
//  IMPLEMENTED IN THIS SLICE: the plumbing plus the position/move ops.
//    0x0205  pos += vel, 8.16 fixed point, and carry the integer delta
//    0x0905  pos += vel (0x0904 is the subtract variant other games use)
//    0x2a05  add a shared delta to two fields
//    0x5205 / 0x5a05  dword copy  cop_regs[0] -> cop_regs[1]
//    0xf205  dword copy  cop_regs[0]+4 -> cop_regs[2]
//    0x3b30/0x3bb0/0x39b0  distance (integer sqrt)
//    0x42c2/0x4aa0         divide
//    0x6200                angle step toward a target
//    0x8100/0x8900         sin / cos, from a Q2.30 table
//    0x130e/0x138e/0x330e/0x338e/0x2208/0x2288  angle from a vector
//    0xa100/0xa900/0xb100/0xb900  collision
//
//  Every one of these is diffed against MAME by sim/tb_cop_cmd.cpp. The trig
//  ops are the interesting case: MAME computes them in C doubles, so the RTL
//  has to reproduce a truncated double exactly. sin/cos does it with a 30-bit
//  fractional table (28 bits was not enough), and the angle ops avoid division
//  entirely -- trunc(atan(t)*128/pi) is just the largest k with
//  tan(k*pi/128) <= t, which reduces to comparisons against a tan table.
//
//  An unimplemented trigger raises cmd_unknown rather than silently doing
//  nothing, the same way the DMA engine treats an unknown mode.
//
//  Raiden II also uploads 0x1905, 0x9100 and 0x9900, which MAME's dispatch does
//  not handle at all. They are left unimplemented deliberately.
//============================================================================

module raiden2_cop_cmd (
    input  logic        clk,
    input  logic        reset,

    // Register window. reg_addr is addr[10:0]; reg_we is a one-clock strobe.
    input  logic [10:0] reg_addr,
    input  logic [15:0] reg_data,
    input  logic  [1:0] reg_be,
    input  logic        reg_we,
    input  logic        reg_rd,

    output logic [15:0] reg_din,
    output logic        reg_din_oe,

    // Work RAM master. Word addressed; read latency RAM_LATENCY clocks.
    output logic [15:0] ram_addr,
    output logic        ram_rd,
    output logic        ram_we,
    // Byte lanes for the write. Word ops drive 2'b11; the 0x6200 macro writes a
    // single byte, so the lane has to be selectable. Byte READS need no help --
    // the whole word comes back and the lane is picked from the address.
    output logic  [1:0] ram_be,
    output logic [15:0] ram_wdata,
    input  logic [15:0] ram_rdata,

    output logic        busy,        // hold the CPU off the bus while high
    output logic        cmd_unknown, // pulses on a trigger we do not implement

    // ---- COP 0x7e05, Raiden DX only ----------------------------------
    // MAME (seibucop_cmd.ipp, tagged "raidendx"):
    //     write_byte(0x470, read_byte(cop_regs[4]))
    // 0x470 is the tile bank register, and on DX its low bits select the
    // FOREGROUND bank. DX issues this ~2,400 times in 45 s to re-bank that
    // layer as it scrolls; ignoring it leaves the foreground stuck on
    // whichever bank was last written, which is a large visible graphics
    // fault. Raiden II never issues this trigger at all.
    output logic        cop_bank_we,   // one-clock strobe
    output logic  [7:0] cop_bank_data, // byte read from [cop_regs[4]]
    // ---- beam probe (#73) --------------------------------------------
    // 0x0205 is the object POSITION UPDATE: pos += vel, and the integer
    // delta is added to the screen coordinate. The plasma ("toothpaste")
    // beam is a chain of objects each advanced by this command, so a beam
    // that will not bend or track is a beam whose segments are not being
    // moved. MAME issues 0x0205 ~2.6x more often than we do, measured over
    // the same gameplay -- these strobes let the board say so directly.
    output logic        dbg_cmd_any,   // any COP command trigger
    output logic        dbg_cmd_0205   // the position-update specifically
);

    // Matches the work RAM in raiden2_main: address in, data out two clocks later.
    localparam int RAM_LATENCY = 2;

    //------------------------------------------------------------------
    // Register file
    //------------------------------------------------------------------
    logic [31:0] cop_regs [0:7];

    // Uploaded macro program, captured for validation and for any future
    // micro-coded implementation. Nothing here drives execution.
    logic [15:0] pgm_latch_addr;
    logic [15:0] pgm_value, pgm_mask, pgm_trigger;

    logic [15:0] cop_status, cop_dist, cop_angle;
    logic [15:0] cop_hit_status;
    logic [15:0] cop_hit_val [0:2];

    // Auxiliary registers the math ops read.
    //   0x41C angle target, 0x41E angle step  (both for the 0x6200 macro)
    //   0x444 scale -- MAME masks it to 2 bits, so (5 - cop_scale) is 2..5 and
    //         the shift below can never go negative.
    logic [15:0] cop_angle_target, cop_angle_step;
    logic  [1:0] cop_scale;

    wire [2:0] reg_idx = reg_addr[3:1];        // 0x4A0/0x4C0 stride is 2 bytes
    wire       hi_reg  = (reg_addr[10:4] == 7'h4A);   // 0x4A0-0x4AF
    wire       lo_reg  = (reg_addr[10:4] == 7'h4C);   // 0x4C0-0x4CF
    // Only 0x4A0-0x4AD / 0x4C0-0x4CD are mapped: seven registers, not eight.
    wire       reg_ok  = (reg_idx <= 3'd6);

    wire       cmd_wr  = reg_we && (reg_addr >= 11'h500) && (reg_addr <= 11'h505);
    assign dbg_cmd_any  = cmd_wr;
    assign dbg_cmd_0205 = cmd_wr && (reg_data == 16'h0205);
    wire [1:0] cmd_ofs = reg_addr[2:1];

    //------------------------------------------------------------------
    // Read-back
    //------------------------------------------------------------------
    always_comb begin
        reg_din    = 16'h0000;
        reg_din_oe = 1'b0;
        if (reg_rd) begin
            if (hi_reg && reg_ok) begin
                reg_din = cop_regs[reg_idx][31:16]; reg_din_oe = 1'b1;
            end else if (lo_reg && reg_ok) begin
                reg_din = cop_regs[reg_idx][15:0];  reg_din_oe = 1'b1;
            end else if (reg_addr == 11'h580 || reg_addr == 11'h581) begin
                reg_din = cop_hit_status; reg_din_oe = 1'b1;
            end else if (reg_addr >= 11'h582 && reg_addr <= 11'h587) begin
                reg_din = cop_hit_val[reg_addr[2:1]]; reg_din_oe = 1'b1;
            end else if (reg_addr == 11'h5B0 || reg_addr == 11'h5B1) begin
                reg_din = cop_status; reg_din_oe = 1'b1;
            end else if (reg_addr == 11'h5B2 || reg_addr == 11'h5B3) begin
                reg_din = cop_dist;   reg_din_oe = 1'b1;
            end else if (reg_addr == 11'h5B4 || reg_addr == 11'h5B5) begin
                reg_din = cop_angle;  reg_din_oe = 1'b1;
            end
        end
    end

    //------------------------------------------------------------------
    // Execution engine
    //
    // Every implemented op is a short sequence of 16-bit work RAM accesses, so
    // rather than a state per op there is one shared micro-sequencer: `step`
    // indexes into a per-op schedule. Dwords are little-endian pairs, matching
    // the V30 and MAME's read_dword/write_dword.
    //------------------------------------------------------------------
    // 4 bits, not 3: the eight original states filled a 3-bit enum exactly, so
    // adding the 0x7e05 pair silently wrapped C_BANK_WAIT onto C_IDLE until
    // the width was widened.
    typedef enum logic [3:0] {
        C_IDLE, C_RD_ADDR, C_RD_WAIT, C_RD_TAKE, C_WR, C_NEXT, C_CALC, C_DONE,
        // 0x7e05 does not fit the microcoded step machine: it reads one byte
        // and writes a REGISTER rather than work RAM, so it gets its own path.
        C_BANK_WAIT, C_BANK_TAKE
    } cstate_t;
    cstate_t cstate;

    logic [15:0] trigger;
    logic  [1:0] ofs;
    logic  [3:0] step;
    logic  [1:0] latency;

    // Iterative integer units. sqrt is 16 restoring steps over a 32-bit
    // radicand; divide is 21 restoring steps, which is the widest the dividend
    // can be ((16-bit cop_dist << 5) = 21 bits).
    logic  [4:0] calc_cnt;
    logic [31:0] sq_rem, sq_val;
    logic [15:0] sq_root;
    logic [31:0] dv_num;
    logic [16:0] dv_rem;
    logic [20:0] dv_quot;
    logic [15:0] dv_den;

    logic [31:0] acc_a, acc_b;      // operand accumulators
    logic [31:0] acc_c, acc_d;
    logic signed [31:0] dxr, dyr;   // registered dx/dy, squared over two cycles
    logic [31:0] sq_x, sq_y;

    // ---- collision state -------------------------------------------------
    // Two slots, filled by a100/a900 (positions) and consumed by b100/b900
    // (hitboxes + the overlap test). The state persists between commands
    // because that is how the game drives it: read both positions, then run
    // the box test for each slot in turn.
    logic signed [15:0] col_pos  [0:1][0:2];
    logic        [15:0] col_flags[0:1];
    logic               col_swap [0:1];
    logic signed [15:0] col_min  [0:1][0:2];
    logic signed [15:0] col_max  [0:1][0:2];
    logic signed  [7:0] hb_dx    [0:2];
    logic        [7:0]  hb_size  [0:2];
    logic        [15:0] cop_hit_baseadr;
    logic [31:0] hitadr2;
    logic        col_slot;      // which slot this command targets
    logic        col_axis3;     // data & 0x0100 -> three axes instead of two
    logic        cmd_swapf;     // data & 0x0080 latched at command start

    // sin(i*pi/128) as signed Q2.30. 30 fractional bits is not arbitrary:
    // an exhaustive sweep of all 256 angles x 256 amplitudes showed 8 exact
    // mismatches against MAME's double at 28 bits and none at 30.
    // cos is the same table read 64 entries along, since cos(x)=sin(x+pi/2).
    logic signed [31:0] sintab [0:255];
    initial begin
        sintab[  0] = 32'sh00000000; sintab[  1] = 32'sh0192155F; sintab[  2] = 32'sh0323ECBE; sintab[  3] = 32'sh04B54825;
        sintab[  4] = 32'sh0645E9AF; sintab[  5] = 32'sh07D59396; sintab[  6] = 32'sh09640837; sintab[  7] = 32'sh0AF10A22;
        sintab[  8] = 32'sh0C7C5C1E; sintab[  9] = 32'sh0E05C135; sintab[ 10] = 32'sh0F8CFCBE; sintab[ 11] = 32'sh1111D263;
        sintab[ 12] = 32'sh1294062F; sintab[ 13] = 32'sh14135C94; sintab[ 14] = 32'sh158F9A76; sintab[ 15] = 32'sh17088531;
        sintab[ 16] = 32'sh187DE2A7; sintab[ 17] = 32'sh19EF7944; sintab[ 18] = 32'sh1B5D100A; sintab[ 19] = 32'sh1CC66E99;
        sintab[ 20] = 32'sh1E2B5D38; sintab[ 21] = 32'sh1F8BA4DC; sintab[ 22] = 32'sh20E70F32; sintab[ 23] = 32'sh223D66A8;
        sintab[ 24] = 32'sh238E7673; sintab[ 25] = 32'sh24DA0A9A; sintab[ 26] = 32'sh261FEFFA; sintab[ 27] = 32'sh275FF452;
        sintab[ 28] = 32'sh2899E64A; sintab[ 29] = 32'sh29CD9578; sintab[ 30] = 32'sh2AFAD269; sintab[ 31] = 32'sh2C216EAA;
        sintab[ 32] = 32'sh2D413CCD; sintab[ 33] = 32'sh2E5A1070; sintab[ 34] = 32'sh2F6BBE45; sintab[ 35] = 32'sh30761C18;
        sintab[ 36] = 32'sh317900D6; sintab[ 37] = 32'sh32744493; sintab[ 38] = 32'sh3367C090; sintab[ 39] = 32'sh34534F41;
        sintab[ 40] = 32'sh3536CC52; sintab[ 41] = 32'sh361214B0; sintab[ 42] = 32'sh36E5068A; sintab[ 43] = 32'sh37AF8159;
        sintab[ 44] = 32'sh387165E3; sintab[ 45] = 32'sh392A9642; sintab[ 46] = 32'sh39DAF5E8; sintab[ 47] = 32'sh3A8269A3;
        sintab[ 48] = 32'sh3B20D79E; sintab[ 49] = 32'sh3BB6276E; sintab[ 50] = 32'sh3C42420A; sintab[ 51] = 32'sh3CC511D9;
        sintab[ 52] = 32'sh3D3E82AE; sintab[ 53] = 32'sh3DAE81CF; sintab[ 54] = 32'sh3E14FDF7; sintab[ 55] = 32'sh3E71E759;
        sintab[ 56] = 32'sh3EC52FA0; sintab[ 57] = 32'sh3F0EC9F5; sintab[ 58] = 32'sh3F4EAAFE; sintab[ 59] = 32'sh3F84C8E2;
        sintab[ 60] = 32'sh3FB11B48; sintab[ 61] = 32'sh3FD39B5A; sintab[ 62] = 32'sh3FEC43C7; sintab[ 63] = 32'sh3FFB10C1;
        sintab[ 64] = 32'sh40000000; sintab[ 65] = 32'sh3FFB10C1; sintab[ 66] = 32'sh3FEC43C7; sintab[ 67] = 32'sh3FD39B5A;
        sintab[ 68] = 32'sh3FB11B48; sintab[ 69] = 32'sh3F84C8E2; sintab[ 70] = 32'sh3F4EAAFE; sintab[ 71] = 32'sh3F0EC9F5;
        sintab[ 72] = 32'sh3EC52FA0; sintab[ 73] = 32'sh3E71E759; sintab[ 74] = 32'sh3E14FDF7; sintab[ 75] = 32'sh3DAE81CF;
        sintab[ 76] = 32'sh3D3E82AE; sintab[ 77] = 32'sh3CC511D9; sintab[ 78] = 32'sh3C42420A; sintab[ 79] = 32'sh3BB6276E;
        sintab[ 80] = 32'sh3B20D79E; sintab[ 81] = 32'sh3A8269A3; sintab[ 82] = 32'sh39DAF5E8; sintab[ 83] = 32'sh392A9642;
        sintab[ 84] = 32'sh387165E3; sintab[ 85] = 32'sh37AF8159; sintab[ 86] = 32'sh36E5068A; sintab[ 87] = 32'sh361214B0;
        sintab[ 88] = 32'sh3536CC52; sintab[ 89] = 32'sh34534F41; sintab[ 90] = 32'sh3367C090; sintab[ 91] = 32'sh32744493;
        sintab[ 92] = 32'sh317900D6; sintab[ 93] = 32'sh30761C18; sintab[ 94] = 32'sh2F6BBE45; sintab[ 95] = 32'sh2E5A1070;
        sintab[ 96] = 32'sh2D413CCD; sintab[ 97] = 32'sh2C216EAA; sintab[ 98] = 32'sh2AFAD269; sintab[ 99] = 32'sh29CD9578;
        sintab[100] = 32'sh2899E64A; sintab[101] = 32'sh275FF452; sintab[102] = 32'sh261FEFFA; sintab[103] = 32'sh24DA0A9A;
        sintab[104] = 32'sh238E7673; sintab[105] = 32'sh223D66A8; sintab[106] = 32'sh20E70F32; sintab[107] = 32'sh1F8BA4DC;
        sintab[108] = 32'sh1E2B5D38; sintab[109] = 32'sh1CC66E99; sintab[110] = 32'sh1B5D100A; sintab[111] = 32'sh19EF7944;
        sintab[112] = 32'sh187DE2A7; sintab[113] = 32'sh17088531; sintab[114] = 32'sh158F9A76; sintab[115] = 32'sh14135C94;
        sintab[116] = 32'sh1294062F; sintab[117] = 32'sh1111D263; sintab[118] = 32'sh0F8CFCBE; sintab[119] = 32'sh0E05C135;
        sintab[120] = 32'sh0C7C5C1E; sintab[121] = 32'sh0AF10A22; sintab[122] = 32'sh09640837; sintab[123] = 32'sh07D59396;
        sintab[124] = 32'sh0645E9AF; sintab[125] = 32'sh04B54825; sintab[126] = 32'sh0323ECBE; sintab[127] = 32'sh0192155F;
        sintab[128] = 32'sh00000000; sintab[129] = 32'shFE6DEAA1; sintab[130] = 32'shFCDC1342; sintab[131] = 32'shFB4AB7DB;
        sintab[132] = 32'shF9BA1651; sintab[133] = 32'shF82A6C6A; sintab[134] = 32'shF69BF7C9; sintab[135] = 32'shF50EF5DE;
        sintab[136] = 32'shF383A3E2; sintab[137] = 32'shF1FA3ECB; sintab[138] = 32'shF0730342; sintab[139] = 32'shEEEE2D9D;
        sintab[140] = 32'shED6BF9D1; sintab[141] = 32'shEBECA36C; sintab[142] = 32'shEA70658A; sintab[143] = 32'shE8F77ACF;
        sintab[144] = 32'shE7821D59; sintab[145] = 32'shE61086BC; sintab[146] = 32'shE4A2EFF6; sintab[147] = 32'shE3399167;
        sintab[148] = 32'shE1D4A2C8; sintab[149] = 32'shE0745B24; sintab[150] = 32'shDF18F0CE; sintab[151] = 32'shDDC29958;
        sintab[152] = 32'shDC71898D; sintab[153] = 32'shDB25F566; sintab[154] = 32'shD9E01006; sintab[155] = 32'shD8A00BAE;
        sintab[156] = 32'shD76619B6; sintab[157] = 32'shD6326A88; sintab[158] = 32'shD5052D97; sintab[159] = 32'shD3DE9156;
        sintab[160] = 32'shD2BEC333; sintab[161] = 32'shD1A5EF90; sintab[162] = 32'shD09441BB; sintab[163] = 32'shCF89E3E8;
        sintab[164] = 32'shCE86FF2A; sintab[165] = 32'shCD8BBB6D; sintab[166] = 32'shCC983F70; sintab[167] = 32'shCBACB0BF;
        sintab[168] = 32'shCAC933AE; sintab[169] = 32'shC9EDEB50; sintab[170] = 32'shC91AF976; sintab[171] = 32'shC8507EA7;
        sintab[172] = 32'shC78E9A1D; sintab[173] = 32'shC6D569BE; sintab[174] = 32'shC6250A18; sintab[175] = 32'shC57D965D;
        sintab[176] = 32'shC4DF2862; sintab[177] = 32'shC449D892; sintab[178] = 32'shC3BDBDF6; sintab[179] = 32'shC33AEE27;
        sintab[180] = 32'shC2C17D52; sintab[181] = 32'shC2517E31; sintab[182] = 32'shC1EB0209; sintab[183] = 32'shC18E18A7;
        sintab[184] = 32'shC13AD060; sintab[185] = 32'shC0F1360B; sintab[186] = 32'shC0B15502; sintab[187] = 32'shC07B371E;
        sintab[188] = 32'shC04EE4B8; sintab[189] = 32'shC02C64A6; sintab[190] = 32'shC013BC39; sintab[191] = 32'shC004EF3F;
        sintab[192] = 32'shC0000000; sintab[193] = 32'shC004EF3F; sintab[194] = 32'shC013BC39; sintab[195] = 32'shC02C64A6;
        sintab[196] = 32'shC04EE4B8; sintab[197] = 32'shC07B371E; sintab[198] = 32'shC0B15502; sintab[199] = 32'shC0F1360B;
        sintab[200] = 32'shC13AD060; sintab[201] = 32'shC18E18A7; sintab[202] = 32'shC1EB0209; sintab[203] = 32'shC2517E31;
        sintab[204] = 32'shC2C17D52; sintab[205] = 32'shC33AEE27; sintab[206] = 32'shC3BDBDF6; sintab[207] = 32'shC449D892;
        sintab[208] = 32'shC4DF2862; sintab[209] = 32'shC57D965D; sintab[210] = 32'shC6250A18; sintab[211] = 32'shC6D569BE;
        sintab[212] = 32'shC78E9A1D; sintab[213] = 32'shC8507EA7; sintab[214] = 32'shC91AF976; sintab[215] = 32'shC9EDEB50;
        sintab[216] = 32'shCAC933AE; sintab[217] = 32'shCBACB0BF; sintab[218] = 32'shCC983F70; sintab[219] = 32'shCD8BBB6D;
        sintab[220] = 32'shCE86FF2A; sintab[221] = 32'shCF89E3E8; sintab[222] = 32'shD09441BB; sintab[223] = 32'shD1A5EF90;
        sintab[224] = 32'shD2BEC333; sintab[225] = 32'shD3DE9156; sintab[226] = 32'shD5052D97; sintab[227] = 32'shD6326A88;
        sintab[228] = 32'shD76619B6; sintab[229] = 32'shD8A00BAE; sintab[230] = 32'shD9E01006; sintab[231] = 32'shDB25F566;
        sintab[232] = 32'shDC71898D; sintab[233] = 32'shDDC29958; sintab[234] = 32'shDF18F0CE; sintab[235] = 32'shE0745B24;
        sintab[236] = 32'shE1D4A2C8; sintab[237] = 32'shE3399167; sintab[238] = 32'shE4A2EFF6; sintab[239] = 32'shE61086BC;
        sintab[240] = 32'shE7821D59; sintab[241] = 32'shE8F77ACF; sintab[242] = 32'shEA70658A; sintab[243] = 32'shEBECA36C;
        sintab[244] = 32'shED6BF9D1; sintab[245] = 32'shEEEE2D9D; sintab[246] = 32'shF0730342; sintab[247] = 32'shF1FA3ECB;
        sintab[248] = 32'shF383A3E2; sintab[249] = 32'shF50EF5DE; sintab[250] = 32'shF69BF7C9; sintab[251] = 32'shF82A6C6A;
        sintab[252] = 32'shF9BA1651; sintab[253] = 32'shFB4AB7DB; sintab[254] = 32'shFCDC1342; sintab[255] = 32'shFE6DEAA1;
    end

    // tan(k*pi/128) as Q6.24, for the division-free angle search below.
    // trunc(atan(t)*128/pi) is the largest k with tan(k*pi/128) <= t, so the
    // whole op reduces to comparisons -- no divide, and exact against MAME's
    // double over 200k random and 90k swept operand pairs.
    logic [29:0] tantab [0:63];
    initial begin
        tantab[ 0] = 30'h00000000; tantab[ 1] = 30'h000648D2; tantab[ 2] = 30'h000C9394; tantab[ 3] = 30'h0012E23A;
        tantab[ 4] = 30'h001936BC; tantab[ 5] = 30'h001F9318; tantab[ 6] = 30'h0025F959; tantab[ 7] = 30'h002C6B93;
        tantab[ 8] = 30'h0032EBEC; tantab[ 9] = 30'h00397C9A; tantab[10] = 30'h00401FEA; tantab[11] = 30'h0046D841;
        tantab[12] = 30'h004DA821; tantab[13] = 30'h0054922C; tantab[14] = 30'h005B9928; tantab[15] = 30'h0062C006;
        tantab[16] = 30'h006A09E6; tantab[17] = 30'h00717A1C; tantab[18] = 30'h00791438; tantab[19] = 30'h0080DC0D;
        tantab[20] = 30'h0088D5B9; tantab[21] = 30'h009105AF; tantab[22] = 30'h009970C4; tantab[23] = 30'h00A21C37;
        tantab[24] = 30'h00AB0DC1; tantab[25] = 30'h00B44BA9; tantab[26] = 30'h00BDDCCF; tantab[27] = 30'h00C7C8CC;
        tantab[28] = 30'h00D21801; tantab[29] = 30'h00DCD3BE; tantab[30] = 30'h00E8065E; tantab[31] = 30'h00F3BB75;
        tantab[32] = 30'h01000000; tantab[33] = 30'h010CE29D; tantab[34] = 30'h011A73D5; tantab[35] = 30'h0128C670;
        tantab[36] = 30'h0137EFD9; tantab[37] = 30'h014808A0; tantab[38] = 30'h01592D11; tantab[39] = 30'h016B7DF8;
        tantab[40] = 30'h017F218E; tantab[41] = 30'h019444A7; tantab[42] = 30'h01AB1C36; tantab[43] = 30'h01C3E738;
        tantab[44] = 30'h01DEF13B; tantab[45] = 30'h01FC95AC; tantab[46] = 30'h021D443B; tantab[47] = 30'h024186D9;
        tantab[48] = 30'h026A09E6; tantab[49] = 30'h0297A7B1; tantab[50] = 30'h02CB78DA; tantab[51] = 30'h0306EC4E;
        tantab[52] = 30'h034BEB3D; tantab[53] = 30'h039D10AD; tantab[54] = 30'h03FE0261; tantab[55] = 30'h04740510;
        tantab[56] = 30'h0506FFB9; tantab[57] = 30'h05C35D46; tantab[58] = 30'h06BDCFD3; tantab[59] = 30'h081B97DA;
        tantab[60] = 30'h0A27362D; tantab[61] = 30'h0D8E81E0; tantab[62] = 30'h145AFFED; tantab[63] = 30'h28BC48AC;
    end

    // ---- 0x130e / 0x338e / 0x2208 / 0x2288 angle from dx,dy ---------------
    // Signed because hi reaches -1 at the low end, and NINE bits rather than
    // seven because at_lo + at_hi reaches 126: at 7 bits that sum overflows to
    // a negative number and every midpoint after it is wrong.
    logic signed [8:0] at_lo, at_hi;
    logic        [5:0] at_k;
    logic       [31:0] at_ax, at_ay;
    logic        [2:0] at_step;         // SEVEN halvings, not six: an interval
    logic        [1:0] at_phase;        // of 64 needs 7 to collapse, and 6 was
    logic       [29:0] at_tanq;         // wrong on 1.2% of operand pairs
    logic       [61:0] at_prod;
    logic              at_neg, at_dyneg, at_dyzero;
    // One-cycle delayed commit of the atan result into cop_angle. The final
    // C_CALC cycle may still be updating at_k (non-blocking), so latching
    // at_res THERE would capture the value one halving early; a cycle later
    // every register feeding at_res is final.
    logic              at_commit;

    wire is_atan = (trigger == 16'h130e) || (trigger == 16'h138e) ||
                   (trigger == 16'h330e) || (trigger == 16'h338e) ||
                   (trigger == 16'h2208) || (trigger == 16'h2288);
    wire signed [8:0] at_mid  = (at_lo + at_hi) >>> 1;
    wire       [61:0] at_lhs  = {6'd0, at_ax, 24'd0};
    wire              at_ge   = at_lhs >= at_prod;
    // Negate in 8 bits, not by pasting a sign onto a 6-bit two's complement:
    // that form gives 0xC0 rather than 0 when at_k is zero.
    wire        [7:0] at_base = at_neg ? (8'd0 - {2'd0, at_k}) : {2'd0, at_k};
    wire        [7:0] at_res  = at_dyzero ? 8'd0
                              : (at_dyneg ? at_base + 8'h80 : at_base);

    // ---- 0x8100 / 0x8900 sin/cos ----------------------------------------
    logic  [7:0] trig_angle;
    logic  [7:0] trig_amp;
    logic signed [31:0] trig_res;

    // amp = (65536 >> 5) * amp8, doubled at one specific angle per op -- a
    // quirk MAME carries because the bootleg does it too.
    wire        trig_is_cos = trigger[11];
    wire        trig_dbl    = trig_is_cos ? (trig_angle == 8'h80)
                                          : (trig_angle == 8'hC0);
    // amp8 << 11 is (65536 >> 5) * amp8; the doubled case needs one more bit,
    // so 21 bits is exactly enough for the largest value (255 << 12).
    wire [20:0] trig_amp_v  = trig_dbl ? ({13'd0, trig_amp} << 12)
                                       : ({13'd0, trig_amp} << 11);
    wire  [7:0] trig_idx    = trig_is_cos ? (trig_angle + 8'd64) : trig_angle;

    // Registered table read. An asynchronous read of 256x32 bits cannot map to
    // a memory block and would land in logic instead.
    logic signed [31:0] sin_q;
    always_ff @(posedge clk) sin_q <= sintab[trig_idx];

    // Pipelined, not one big expression. Multiply, magnitude and the variable
    // shift in a single cycle formed the critical path of the whole design at
    // -2.386 ns; the calc window is 21 cycles, so there is room to spare.
    logic signed [53:0] trig_prod_r;
    logic signed [53:0] trig_abs_r;
    logic               trig_sign_r;
    always_ff @(posedge clk) begin
        trig_prod_r <= $signed({1'b0, trig_amp_v}) * sin_q;
        trig_sign_r <= trig_prod_r[53];
        // int() in C truncates toward zero, which is not an arithmetic shift.
        trig_abs_r  <= trig_prod_r[53] ? -trig_prod_r : trig_prod_r;
    end
    wire signed [31:0] trig_q = trig_sign_r ? -$signed({9'd0, trig_abs_r[52:30]})
                                            :  $signed({9'd0, trig_abs_r[52:30]});

    // 0x6200 angle rotation, all integer.
    logic  [7:0] ang_cur;
    logic [15:0] ang_flags;
    wire   [7:0] ang_tgt  = cop_angle_target[7:0];
    wire   [7:0] ang_stp  = cop_angle_step[7:0];
    // delta = angle - target, wrapped into -128..127
    wire signed [8:0] ang_d0  = $signed({1'b0, ang_cur}) - $signed({1'b0, ang_tgt});
    wire signed [8:0] ang_d   = (ang_d0 >= 9'sd128)  ? ang_d0 - 9'sd256
                              : (ang_d0 <  -9'sd128) ? ang_d0 + 9'sd256 : ang_d0;
    wire        ang_neg  = ang_d[8];
    wire        ang_snap = ang_neg ? (ang_d >= -$signed({1'b0, ang_stp}))
                                   : (ang_d <=  $signed({1'b0, ang_stp}));
    wire  [7:0] ang_next = ang_snap ? ang_tgt
                         : ang_neg  ? (ang_cur + ang_stp)
                                    : (ang_cur - ang_stp);
    wire [15:0] ang_flags_next = (ang_flags & ~16'h0004) | (ang_snap ? 16'h0004 : 16'h0000);
    logic        div_zero;          // 0x42c2 divide-by-zero -> status bit 15
    logic [15:0] delta;             // 0x0205 / 0x2a05 integer delta
    logic [31:0] ea;                // effective byte address for this access
    logic        is_write;
    logic        last_step;

    // Byte address -> word address for the RAM port.
    assign ram_addr = ea[16:1];

    // A byte read just takes the addressed lane of the returned word.
    wire [7:0] rd_byte = ea[0] ? ram_rdata[15:8] : ram_rdata[7:0];

    wire [31:0] r0 = cop_regs[0];
    wire [31:0] r1 = cop_regs[1];
    wire [31:0] r2 = cop_regs[2];
    wire [31:0] ofs4 = {28'd0, ofs, 2'b00};   // offset * 4

    // Per-op schedule. Each step names an address, a direction, and (for
    // writes) which half of which accumulator to emit.
    logic [31:0] nx_ea;
    logic        nx_wr;
    logic [15:0] nx_wdata;
    logic        nx_last;
    logic        nx_calc;   // this step runs the iterative unit, not a RAM access
    logic        nx_skip;   // this step does nothing at all (conditional store)
    logic  [1:0] nx_be;     // byte lanes for a write

    // Which object this collision command targets. a100/b100 -> slot 0,
    // a900/b900 -> slot 1; the position ops read cop_regs[0]/[1] and the
    // hitbox ops cop_regs[2]/[3].
    wire        col_is_hi  = trigger[11];                 // a900/b900 vs a100/b100
    wire        col_is_box = (trigger[15:12] == 4'hB);
    wire [31:0] col_base   = col_is_box ? (col_is_hi ? cop_regs[3] : cop_regs[2])
                                        : (col_is_hi ? cop_regs[1] : cop_regs[0]);

    // Per-axis box for the slot this b100/b900 targets. `swap` mirrors the box
    // around the object's position, which is how facing is handled.
    // All arithmetic is int16, matching MAME's colinfo.
    logic signed [15:0] nmin [0:2];
    logic signed [15:0] nmax [0:2];
    always_comb begin
        for (int i = 0; i < 3; i++) begin
            if (col_swap[col_slot] && col_flags[col_slot][i]) begin
                nmax[i] = col_pos[col_slot][i] - {{8{hb_dx[i][7]}}, hb_dx[i]};
                nmin[i] = nmax[i] - {8'd0, hb_size[i]};
            end else begin
                nmin[i] = col_pos[col_slot][i] + {{8{hb_dx[i][7]}}, hb_dx[i]};
                nmax[i] = nmin[i] + {8'd0, hb_size[i]};
            end
        end
    end

    // The overlap test compares BOTH slots, and MAME runs it with the slot
    // under test already updated -- so that slot reads from the combinational
    // box above while the other reads from its stored one.
    logic signed [15:0] b0min [0:2], b0max [0:2];
    logic signed [15:0] b1min [0:2], b1max [0:2];
    logic         [2:0] axis_overlap;
    logic        [15:0] col_res;
    always_comb begin
        for (int i = 0; i < 3; i++) begin
            b0min[i] = (col_slot == 1'b0) ? nmin[i] : col_min[0][i];
            b0max[i] = (col_slot == 1'b0) ? nmax[i] : col_max[0][i];
            b1min[i] = (col_slot == 1'b1) ? nmin[i] : col_min[1][i];
            b1max[i] = (col_slot == 1'b1) ? nmax[i] : col_max[1][i];
            axis_overlap[i] = ((b0max[i] > b1min[i]) && (b0min[i] < b1max[i]))
                           || ((b1max[i] > b0min[i]) && (b1min[i] < b0max[i]));
        end
        // A bit is CLEARED when that axis overlaps, so 0 means "hit on every
        // axis". That is MAME's polarity and the game depends on it.
        col_res = (col_axis3 ? 16'd7 : 16'd3) & ~{13'd0, axis_overlap};
        if (!col_axis3) col_res[2] = 1'b0;
    end

    always_comb begin
        nx_ea    = 32'd0;
        nx_wr    = 1'b0;
        nx_wdata = 16'd0;
        nx_last  = 1'b1;
        nx_calc  = 1'b0;
        nx_skip  = 1'b0;
        nx_be    = 2'b11;

        case (trigger)
        //--------------------------------------------------------------
        // 0x0205: ppos  = dword[r0+0x04+o*4]
        //         npos  = ppos + dword[r0+0x10+o*4]
        //         delta = (npos>>16) - (ppos>>16)
        //         dword[r0+0x04+o*4] = npos
        //         word [r0+0x1e+o*4] += delta
        //--------------------------------------------------------------
        16'h0205: case (step)
            4'd0: begin nx_ea = r0 + 32'h04 + ofs4;      nx_last = 0; end
            4'd1: begin nx_ea = r0 + 32'h06 + ofs4;      nx_last = 0; end
            4'd2: begin nx_ea = r0 + 32'h10 + ofs4;      nx_last = 0; end
            4'd3: begin nx_ea = r0 + 32'h12 + ofs4;      nx_last = 0; end
            4'd4: begin nx_ea = r0 + 32'h04 + ofs4; nx_wr = 1; nx_wdata = acc_a[15:0];  nx_last = 0; end
            4'd5: begin nx_ea = r0 + 32'h06 + ofs4; nx_wr = 1; nx_wdata = acc_a[31:16]; nx_last = 0; end
            4'd6: begin nx_ea = r0 + 32'h1e + ofs4;      nx_last = 0; end
            default: begin nx_ea = r0 + 32'h1e + ofs4; nx_wr = 1; nx_wdata = acc_b[15:0]; end
        endcase

        //--------------------------------------------------------------
        // 0x0905: dword[r0+0x10+o*4] +/- dword[r0+0x28+o*4]
        // Bit 0 of the trigger selects add (0x0905) or subtract (0x0904).
        //--------------------------------------------------------------
        16'h0905, 16'h0904: case (step)
            4'd0: begin nx_ea = r0 + 32'h10 + ofs4;      nx_last = 0; end
            4'd1: begin nx_ea = r0 + 32'h12 + ofs4;      nx_last = 0; end
            4'd2: begin nx_ea = r0 + 32'h28 + ofs4;      nx_last = 0; end
            4'd3: begin nx_ea = r0 + 32'h2a + ofs4;      nx_last = 0; end
            4'd4: begin nx_ea = r0 + 32'h10 + ofs4; nx_wr = 1; nx_wdata = acc_a[15:0];  nx_last = 0; end
            default: begin nx_ea = r0 + 32'h12 + ofs4; nx_wr = 1; nx_wdata = acc_a[31:16]; end
        endcase

        //--------------------------------------------------------------
        // 0x2a05: delta = word[r1+0x1e+o*4]
        //         dword[r0+0x06+o*4] = word[r0+0x06+o*4] + delta
        //         dword[r0+0x1e+o*4] = word[r0+0x1e+o*4] + delta
        //
        // MAME reads a WORD and writes a DWORD at both destinations, so the
        // upper half is the carry-out of a 16-bit add rather than a preserved
        // value. That asymmetry looks like a bug but it is what the working
        // implementation does, so it is reproduced rather than tidied.
        //--------------------------------------------------------------
        16'h2a05: case (step)
            4'd0: begin nx_ea = r1 + 32'h1e + ofs4;      nx_last = 0; end
            4'd1: begin nx_ea = r0 + 32'h06 + ofs4;      nx_last = 0; end
            4'd2: begin nx_ea = r0 + 32'h06 + ofs4; nx_wr = 1; nx_wdata = acc_a[15:0];  nx_last = 0; end
            4'd3: begin nx_ea = r0 + 32'h08 + ofs4; nx_wr = 1; nx_wdata = acc_a[31:16]; nx_last = 0; end
            4'd4: begin nx_ea = r0 + 32'h1e + ofs4;      nx_last = 0; end
            4'd5: begin nx_ea = r0 + 32'h1e + ofs4; nx_wr = 1; nx_wdata = acc_a[15:0];  nx_last = 0; end
            default: begin nx_ea = r0 + 32'h20 + ofs4; nx_wr = 1; nx_wdata = acc_a[31:16]; end
        endcase

        //--------------------------------------------------------------
        // 0x5205 / 0x5a05: dword[r1] = dword[r0]
        //--------------------------------------------------------------
        16'h5205, 16'h5a05: case (step)
            4'd0: begin nx_ea = r0;                      nx_last = 0; end
            4'd1: begin nx_ea = r0 + 32'd2;              nx_last = 0; end
            4'd2: begin nx_ea = r1;         nx_wr = 1; nx_wdata = acc_a[15:0];  nx_last = 0; end
            default: begin nx_ea = r1 + 32'd2; nx_wr = 1; nx_wdata = acc_a[31:16]; end
        endcase

        //--------------------------------------------------------------
        // 0xf205: dword[r2] = dword[r0+4]
        //--------------------------------------------------------------
        16'hf205: case (step)
            4'd0: begin nx_ea = r0 + 32'd4;              nx_last = 0; end
            4'd1: begin nx_ea = r0 + 32'd6;              nx_last = 0; end
            4'd2: begin nx_ea = r2;         nx_wr = 1; nx_wdata = acc_a[15:0];  nx_last = 0; end
            default: begin nx_ea = r2 + 32'd2; nx_wr = 1; nx_wdata = acc_a[31:16]; end
        endcase

        //--------------------------------------------------------------
        // 0x130e / 0x338e -- angle from the vector between two objects
        //   dx = dword[r1+4] - dword[r0+4], dy = dword[r1+8] - dword[r0+8]
        //   dy == 0 : status |= 0x8000, angle = 0
        //   else    : angle = int(atan(dx/dy)*128/pi), +0x80 when dy < 0
        //   data & 0x80 stores it at byte[r0+0x34]; 130e also flips it by 0x80.
        //--------------------------------------------------------------
        16'h130e, 16'h138e, 16'h330e, 16'h338e: case (step)
            4'd0: begin nx_ea = r0 + 32'h04;             nx_last = 0; end
            4'd1: begin nx_ea = r0 + 32'h06;             nx_last = 0; end
            4'd2: begin nx_ea = r1 + 32'h04;             nx_last = 0; end
            4'd3: begin nx_ea = r1 + 32'h06;             nx_last = 0; end
            4'd4: begin nx_ea = r0 + 32'h08;             nx_last = 0; end
            4'd5: begin nx_ea = r0 + 32'h0a;             nx_last = 0; end
            4'd6: begin nx_ea = r1 + 32'h08;             nx_last = 0; end
            4'd7: begin nx_ea = r1 + 32'h0a;             nx_last = 0; end
            4'd8: begin nx_calc = 1;                     nx_last = 0; end
            default: begin
                nx_ea = r0 + 32'h34; nx_wr = 1; nx_be = 2'b01;
                nx_wdata = {at_res, at_res};
                nx_skip  = ~trigger[7];
            end
        endcase

        //--------------------------------------------------------------
        // 0x2208 / 0x2288 -- angle from a dx,dy pair held in the object
        //   Both are read with read_word into an int, so they are ZERO
        //   extended -- unlike 338e these are never negative.
        //--------------------------------------------------------------
        16'h2208, 16'h2288: case (step)
            4'd0: begin nx_ea = r0 + 32'h12;             nx_last = 0; end
            4'd1: begin nx_ea = r0 + 32'h16;             nx_last = 0; end
            4'd2: begin nx_calc = 1;                     nx_last = 0; end
            default: begin
                nx_ea = r0 + 32'h34; nx_wr = 1; nx_be = 2'b01;
                nx_wdata = {at_res, at_res};
                nx_skip  = ~trigger[7];
            end
        endcase

        //--------------------------------------------------------------
        // 0x8100 / 0x8900 -- sin / cos
        //   raw = byte[r0+0x34], amp8 = byte[r0+0x36]
        //   dword[r0+0x10] = int(amp * sin(raw*pi/128)) << scale   (8100)
        //   dword[r0+0x14] = int(amp * cos(raw*pi/128)) << scale   (8900)
        //--------------------------------------------------------------
        16'h8100, 16'h8900: case (step)
            4'd0: begin nx_ea = r0 + 32'h34;             nx_last = 0; end
            4'd1: begin nx_ea = r0 + 32'h36;             nx_last = 0; end
            4'd2: begin nx_calc = 1;                     nx_last = 0; end
            4'd3: begin nx_ea = r0 + (trigger[11] ? 32'h14 : 32'h10);
                        nx_wr = 1; nx_wdata = trig_res[15:0];  nx_last = 0; end
            default: begin nx_ea = r0 + (trigger[11] ? 32'h16 : 32'h12);
                        nx_wr = 1; nx_wdata = trig_res[31:16]; end
        endcase

        //--------------------------------------------------------------
        // 0x3b30 / 0x3bb0 / 0x39b0 -- distance (sqrt)
        //   dx = dword[r1+4] - dword[r0+4],  dy = dword[r1+8] - dword[r0+8]
        //   cop_dist = floor(sqrt((dx>>16)^2 + (dy>>16)^2))
        //   if data & 0x80: word[r0 + (data&0x200 ? 0x3a : 0x38)] = cop_dist
        //
        // MAME computes the sqrt in double, but the argument is an exact
        // integer, so floor(sqrt(n)) is exactly the integer square root and an
        // iterative unit matches it bit for bit.
        //--------------------------------------------------------------
        16'h3b30, 16'h3bb0, 16'h39b0: case (step)
            4'd0: begin nx_ea = r0 + 32'h04;             nx_last = 0; end
            4'd1: begin nx_ea = r0 + 32'h06;             nx_last = 0; end
            4'd2: begin nx_ea = r1 + 32'h04;             nx_last = 0; end
            4'd3: begin nx_ea = r1 + 32'h06;             nx_last = 0; end
            4'd4: begin nx_ea = r0 + 32'h08;             nx_last = 0; end
            4'd5: begin nx_ea = r0 + 32'h0a;             nx_last = 0; end
            4'd6: begin nx_ea = r1 + 32'h08;             nx_last = 0; end
            4'd7: begin nx_ea = r1 + 32'h0a;             nx_last = 0; end
            4'd8: begin nx_calc = 1;                     nx_last = 0; end
            default: begin
                nx_ea = r0 + (trigger[9] ? 32'h3a : 32'h38);
                nx_wr = 1; nx_wdata = cop_dist;
                // Bit 7 clear means compute cop_dist but do not store it.
                nx_skip = ~trigger[7];
            end
        endcase

        //--------------------------------------------------------------
        // 0x42c2 -- divide.  div = word[r0+0x36]
        //   div == 0 : status |= 0x8000 and word[r0+0x38] = 0
        //   else     : status = 7, word[r0+0x38] = (dist << (5-scale)) / div
        //--------------------------------------------------------------
        16'h42c2: case (step)
            4'd0: begin nx_ea = r0 + 32'h36;             nx_last = 0; end
            4'd1: begin nx_calc = 1;                     nx_last = 0; end
            default: begin nx_ea = r0 + 32'h38; nx_wr = 1; nx_wdata = acc_a[15:0]; end
        endcase

        //--------------------------------------------------------------
        // 0x4aa0 -- the same divide the other way round, and a zero divisor is
        // forced to 1 instead of raising an error.
        //--------------------------------------------------------------
        16'h4aa0: case (step)
            4'd0: begin nx_ea = r0 + 32'h38;             nx_last = 0; end
            4'd1: begin nx_calc = 1;                     nx_last = 0; end
            default: begin nx_ea = r0 + 32'h36; nx_wr = 1; nx_wdata = acc_a[15:0]; end
        endcase

        //--------------------------------------------------------------
        // 0x6200 -- rotate the current angle towards the target by at most
        // one step, and flag arrival in bit 2 of the object's flags word.
        // The angle is a BYTE at r0+0x34; the flags are a word at r0.
        //--------------------------------------------------------------
        16'h6200: case (step)
            4'd0: begin nx_ea = r0 + 32'h34;             nx_last = 0; end
            4'd1: begin nx_ea = r0;                      nx_last = 0; end
            4'd2: begin nx_ea = r0; nx_wr = 1; nx_be = 2'b11;
                        nx_wdata = ang_flags_next;       nx_last = 0; end
            default: begin
                nx_ea = r0 + 32'h34; nx_wr = 1;
                nx_be = 2'b01;                  // 0x34 is even: low lane
                nx_wdata = {ang_next, ang_next};
            end
        endcase

        //--------------------------------------------------------------
        // 0xa100 / 0xa900 -- latch one object's collision position.
        // a100 uses cop_regs[0] and slot 0, a900 cop_regs[1] and slot 1.
        //--------------------------------------------------------------
        16'ha100, 16'ha180, 16'ha900, 16'ha980: case (step)
            4'd0: begin nx_ea = col_base + 32'd2;        nx_last = 0; end
            4'd1: begin nx_ea = col_base + 32'd6;        nx_last = 0; end
            4'd2: begin nx_ea = col_base + 32'd10;       nx_last = 0; end
            default: begin nx_ea = col_base + 32'd14; end
        endcase

        //--------------------------------------------------------------
        // 0xb100 / 0xb900 -- load this slot's hitbox and run the overlap test.
        // The hitbox pointer is a word in work RAM at cop_regs[2] (or [3]),
        // combined with cop_hit_baseadr as the high half; the box itself is
        // consecutive BYTES of (dx, size) per axis.
        //--------------------------------------------------------------
        16'hb100, 16'hb900: case (step)
            4'd0: begin nx_ea = col_base;                nx_last = 0; end
            4'd1: begin nx_ea = hitadr2 + 32'd0;         nx_last = 0; end
            4'd2: begin nx_ea = hitadr2 + 32'd1;         nx_last = 0; end
            4'd3: begin nx_ea = hitadr2 + 32'd2;         nx_last = 0; end
            4'd4: begin nx_ea = hitadr2 + 32'd3;         nx_last = 0; end
            4'd5: begin nx_ea = hitadr2 + 32'd4; nx_skip = ~col_axis3; nx_last = 0; end
            4'd6: begin nx_ea = hitadr2 + 32'd5; nx_skip = ~col_axis3; nx_last = 0; end
            default: begin nx_calc = 1; end     // one settled cycle to evaluate
        endcase

        default: ;   // unimplemented: never entered, cmd_unknown fires instead
        endcase
    end

    // 0x0205's new position, as a full 32-bit add. Computing the carry inline
    // as `(acc_b[15:0] + acc_a[15:0]) >> 16` does NOT work: both operands are
    // 16 bits, so Verilog does the add at 16 bits and the carry is discarded
    // before the shift ever sees it. delta then reads as vel_hi with no carry,
    // which is wrong exactly when a position crosses a 16-bit boundary --
    // i.e. every time an object moves a whole pixel.
    wire [31:0] npos_next = acc_b + {ram_rdata, acc_a[15:0]};

    // One restoring step of each iterative unit, as plain combinational logic.
    // Kept out of the always_ff deliberately: Quartus 17.0 is unreliable with
    // `automatic` variables inside procedural blocks.
    wire [31:0] sq_r2    = {sq_rem[29:0], sq_val[31:30]};
    // Restoring square root: the trial subtrahend is 4*root + 1, because the
    // remainder is shifted by TWO bits each step while the root grows by one.
    // (root<<1)|1 looks plausible and is wrong -- it gives sqrt(35) = 7.
    wire [31:0] sq_trial = {14'd0, sq_root, 2'b00} | 32'd1;
    wire        sq_ge    = (sq_r2 >= sq_trial);
    wire [16:0] dv_r1    = {dv_rem[15:0], dv_num[20]};
    wire        dv_ge    = (dv_r1 >= {1'b0, dv_den});

    // dx / dy for the distance op, and the radicand. Both differences are taken
    // at full width and only then shifted down by 16, exactly as MAME does.
    wire [31:0] dist_dx  = acc_b - acc_a;
    wire [31:0] dist_dy  = {ram_rdata, acc_d[15:0]} - acc_c;
    // Sign-extend to 32 bits BEFORE squaring. A 16x16 multiply in Verilog is
    // self-determined at 16 bits, so `dx16 * dx16` silently truncates the
    // product to 16 bits no matter how wide the destination is -- the squares
    // came out ~5000x too small. Widening the operands makes the product 32
    // bits, which also matches the int overflow behaviour of MAME's C.
    wire signed [31:0] dx32 = $signed({{16{dist_dx[31]}}, dist_dx[31:16]});
    wire signed [31:0] dy32 = $signed({{16{dist_dy[31]}}, dist_dy[31:16]});

    // dx*dx + dy*dy must NOT be computed in one cycle. Doing so put two 32x32
    // multiplies and an adder on a combinational path straight from the work
    // RAM output to sq_val, and clk_sys missed timing by 1.447 ns (the worst
    // path was literally wram_lo -> sq_val[29]).
    //
    // The shared calc counter already idles for five cycles before the square
    // root needs its radicand, so the work fits there for free: one squaring
    // per cycle through a single shared multiplier, then the sum.
    wire signed [31:0] mul_in = (calc_cnt == 5'd20) ? dxr : dyr;
    wire        [31:0] mul_sq = $unsigned(mul_in * mul_in);

    // (cop_dist << (5 - cop_scale)); cop_scale is masked to 2 bits so the
    // shift is 2..5 and the result never exceeds 21 bits.
    wire [31:0] div_num = {16'd0, cop_dist} << (3'd5 - {1'b0, cop_scale});

    wire trigger_known = (trigger == 16'h0205) || (trigger == 16'h0905) ||
                         (trigger == 16'h0904) || (trigger == 16'h2a05) ||
                         (trigger == 16'h5205) || (trigger == 16'h5a05) ||
                         (trigger == 16'hf205) ||
                         (trigger == 16'h3b30) || (trigger == 16'h3bb0) ||
                         (trigger == 16'h39b0) ||
                         (trigger == 16'h42c2) || (trigger == 16'h4aa0) ||
                         (trigger == 16'h6200) ||
                         (trigger == 16'h8100) || (trigger == 16'h8900) ||
                         (trigger == 16'h130e) || (trigger == 16'h338e) ||
                         (trigger == 16'h138e) || (trigger == 16'h330e) ||
                         (trigger == 16'h2208) || (trigger == 16'h2288) ||
                         (trigger == 16'ha100) || (trigger == 16'ha180) ||
                         (trigger == 16'ha900) || (trigger == 16'ha980) ||
                         (trigger == 16'hb100) || (trigger == 16'hb900);

    wire cmd_known = (reg_data == 16'h7e05) ||
                     (reg_data == 16'h0205) || (reg_data == 16'h0905) ||
                     (reg_data == 16'h0904) || (reg_data == 16'h2a05) ||
                     (reg_data == 16'h5205) || (reg_data == 16'h5a05) ||
                     (reg_data == 16'hf205) ||
                     (reg_data == 16'h3b30) || (reg_data == 16'h3bb0) ||
                     (reg_data == 16'h39b0) ||
                     (reg_data == 16'h42c2) || (reg_data == 16'h4aa0) ||
                     (reg_data == 16'h6200) ||
                     (reg_data == 16'h8100) || (reg_data == 16'h8900) ||
                     (reg_data == 16'h130e) || (reg_data == 16'h338e) ||
                     (reg_data == 16'h138e) || (reg_data == 16'h330e) ||
                     (reg_data == 16'h2208) || (reg_data == 16'h2288) ||
                     (reg_data == 16'ha100) || (reg_data == 16'ha180) ||
                     (reg_data == 16'ha900) || (reg_data == 16'ha980) ||
                     (reg_data == 16'hb100) || (reg_data == 16'hb900);

    assign busy = (cstate != C_IDLE);

    always_ff @(posedge clk) begin
        ram_rd      <= 1'b0;
        ram_we      <= 1'b0;
        cmd_unknown <= 1'b0;
        cop_bank_we <= 1'b0;   // one-clock strobe, same as cmd_unknown

        if (reset) begin
            cstate     <= C_IDLE;
            cop_status <= 16'd0;
            cop_dist   <= 16'd0;
            cop_angle  <= 16'd0;
            at_commit  <= 1'b0;
            cop_hit_status <= 16'd0;
            for (int i = 0; i < 8; i++) cop_regs[i] <= 32'd0;
            for (int i = 0; i < 3; i++) cop_hit_val[i] <= 16'd0;
            pgm_latch_addr <= 16'd0;
            trigger    <= 16'd0;
        end else begin
            //----------------------------------------------------------
            // #73 THE BEAM BUG. cop_angle was declared, wired into the 0x5B4
            // read mux -- and never driven anywhere: its only assignment was
            // the reset. The atan family computed at_res correctly and wrote
            // it to r0+0x34 when trigger bit 7 asked, but 0x130E has bit 7
            // CLEAR -- its ONLY output is this register. The game's aiming
            // loop is 130E -> read 0x5B4 -> feed 0x41C as the 6200 target, so
            // every read returned 0 and the plasma beam flew straight up
            // forever. Same wired-but-never-driven class as #60/#61/#65, and
            // invisible to tb_cop_cmd because that bench only diffs RAM.
            // Proven against 906 real-MAME gameplay vectors (make vec-run).
            if (at_commit) begin
                cop_angle <= {8'd0, at_res};
                at_commit <= 1'b0;
            end

            //----------------------------------------------------------
            // Register writes. Accepted even while the engine is running;
            // the CPU is stalled off the bus for that window anyway.
            //----------------------------------------------------------
            if (reg_we) begin
                if (hi_reg && reg_ok) begin
                    if (reg_be[0]) cop_regs[reg_idx][23:16] <= reg_data[7:0];
                    if (reg_be[1]) cop_regs[reg_idx][31:24] <= reg_data[15:8];
                end
                if (lo_reg && reg_ok) begin
                    if (reg_be[0]) cop_regs[reg_idx][7:0]   <= reg_data[7:0];
                    if (reg_be[1]) cop_regs[reg_idx][15:8]  <= reg_data[15:8];
                end

                // Macro program upload -- captured, never executed. See header.
                case (reg_addr)
                    11'h434: pgm_latch_addr <= reg_data;
                    11'h438: pgm_value      <= reg_data;
                    11'h43a: pgm_mask       <= reg_data;
                    11'h43c: pgm_trigger    <= reg_data;
                    11'h41c: cop_angle_target <= reg_data;
                    11'h41e: cop_angle_step   <= reg_data;
                    11'h436: cop_hit_baseadr  <= reg_data;
                    11'h444: cop_scale        <= reg_data[1:0];   // MAME: &= 3
                    default: ;
                endcase
            end

            case (cstate)
                C_IDLE: begin
                    if (cmd_wr) begin
                        // MAME clears the top status bit on every command.
                        cop_status <= cop_status & 16'h7fff;
                        if (reg_data == 16'h7e05) begin
                            // Read the byte at cop_regs[4]; the register write
                            // to 0x470 happens in C_BANK_TAKE. ram_addr is
                            // ea[16:1], so the byte lane comes from ea[0].
                            trigger <= reg_data;
                            ea      <= cop_regs[4];
                            latency <= RAM_LATENCY[1:0];
                            cstate  <= C_BANK_WAIT;
                        end else if (cmd_known) begin
                            trigger   <= reg_data;
                            cmd_swapf <= reg_data[7];    // allow_swap
                            col_axis3 <= reg_data[8];    // 3 axes instead of 2
                            col_slot  <= reg_data[11];
                            ofs       <= cmd_ofs;
                            step    <= 4'd0;
                            acc_a   <= 32'd0;
                            acc_b   <= 32'd0;
                            cstate  <= C_RD_ADDR;
                        end else begin
                            cmd_unknown <= 1'b1;
                        end
                    end
                end

                // Present the address for this step.
                C_RD_ADDR: begin
                    ea       <= nx_ea;
                    is_write <= nx_wr;
                    last_step<= nx_last;
                    ram_wdata<= nx_wdata;
                    ram_be   <= nx_be;
                    if (nx_skip) begin
                        // Conditional store that this trigger suppresses.
                        cstate <= C_NEXT;
                    end else if (nx_calc) begin
                        calc_cnt <= 5'd20;
                        cstate   <= C_CALC;
                    end else if (nx_wr) begin
                        cstate <= C_WR;
                    end else begin
                        latency <= RAM_LATENCY[1:0];
                        cstate  <= C_RD_WAIT;
                    end
                end

                // One restoring step per clock. Both units run off the same
                // counter; only the one this trigger needs is consumed.
                C_CALC: begin
                    // ---- angle search: table read, multiply, compare -------
                    // Split over three cycles so neither the 64-entry table
                    // read nor the 30x32 multiply sits in the compare path.
                    if (is_atan) begin
                        case (at_phase)
                            2'd0: begin at_tanq  <= tantab[at_mid[5:0]]; at_phase <= 2'd1; end
                            2'd1: begin at_prod  <= {32'd0, at_tanq} * {30'd0, at_ay};
                                        at_phase <= 2'd2; end
                            default: begin
                                if (at_lo <= at_hi) begin
                                    if (at_ge) begin
                                        at_k  <= at_mid[5:0];
                                        at_lo <= at_mid + 9'sd1;
                                    end else begin
                                        at_hi <= at_mid - 9'sd1;
                                    end
                                end
                                at_phase <= 2'd0;
                                at_step  <= at_step + 3'd1;
                                if (at_step == 3'd6) begin
                                    cop_status <= at_dyzero ? (16'd7 | 16'h8000) : 16'd7;
                                    at_commit  <= 1'b1;
                                    cstate     <= C_NEXT;
                                end
                            end
                        endcase
                    end else begin
                    // Radicand pipeline, using the idle head of the counter.
                    if (calc_cnt == 5'd20) sq_x <= mul_sq;
                    if (calc_cnt == 5'd19) sq_y <= mul_sq;
                    if (calc_cnt == 5'd18) begin
                        sq_val  <= sq_x + sq_y;
                        sq_rem  <= 32'd0;
                        sq_root <= 16'd0;
                    end

                    // sqrt consumes only the last 16 of the 21 steps; the
                    // shared counter simply runs long enough for both units.
                    if (calc_cnt <= 5'd15) begin
                        sq_rem  <= sq_ge ? (sq_r2 - sq_trial) : sq_r2;
                        sq_root <= {sq_root[14:0], sq_ge};
                        sq_val  <= {sq_val[29:0], 2'b00};
                    end

                    dv_rem  <= dv_ge ? (dv_r1 - {1'b0, dv_den}) : dv_r1;
                    dv_quot <= {dv_quot[19:0], dv_ge};
                    dv_num  <= {dv_num[30:0], 1'b0};

                    if (calc_cnt == 5'd0 && (trigger == 16'hb100 || trigger == 16'hb900)) begin
                        for (int i = 0; i < 3; i++) begin
                            col_min[col_slot][i] <= nmin[i];
                            col_max[col_slot][i] <= nmax[i];
                            cop_hit_val[i] <= col_pos[0][i] - col_pos[1][i];
                        end
                        cop_hit_status <= col_res;
                        cstate <= C_NEXT;
                    end else if (calc_cnt == 5'd0) begin
                        if (trigger == 16'h3b30 || trigger == 16'h3bb0 ||
                            trigger == 16'h39b0) begin
                            cop_dist <= {sq_root[14:0], sq_ge};
                        end else if (is_atan) begin
                            // handled by the phase machine below
                        end else if (trigger == 16'h8100 || trigger == 16'h8900) begin
                            // sin_q has long since settled: the table read was
                            // issued when the angle byte landed, several steps
                            // back, and the shared counter runs 21 cycles here.
                            trig_res <= trig_q <<< cop_scale;
                        end else if (div_zero) begin
                            // MAME writes 0 and flags status bit 15 instead of
                            // dividing; it does NOT set status to 7 here.
                            acc_a      <= 32'd0;
                            cop_status <= cop_status | 16'h8000;
                        end else begin
                            acc_a      <= {11'd0, dv_quot[19:0], dv_ge};
                            cop_status <= 16'd7;
                        end
                        cstate <= C_NEXT;
                    end else begin
                        calc_cnt <= calc_cnt - 5'd1;
                    end
                    end
                end

                C_RD_WAIT: begin
                    ram_rd <= 1'b1;
                    if (latency == 2'd0) cstate <= C_RD_TAKE;
                    else                 latency <= latency - 2'd1;
                end

                // Fold the returned word into the op's accumulators.
                C_RD_TAKE: begin
                    case (trigger)
                    16'h0205: case (step)
                        4'd0: acc_b[15:0]  <= ram_rdata;             // ppos lo
                        4'd1: acc_b[31:16] <= ram_rdata;             // ppos hi
                        4'd2: acc_a[15:0]  <= ram_rdata;             // vel lo
                        4'd3: begin
                            // npos = ppos + vel; delta = high-word difference.
                            // MAME sign-extends both halves before subtracting,
                            // but only the low 16 bits are ever stored, and
                            // those are identical either way.
                            acc_a <= npos_next;
                            delta <= npos_next[31:16] - acc_b[31:16];
                        end
                        4'd6: acc_b[15:0] <= ram_rdata + delta;
                        default: ;
                    endcase
                    16'h0905, 16'h0904: case (step)
                        4'd0: acc_a[15:0]  <= ram_rdata;
                        4'd1: acc_a[31:16] <= ram_rdata;
                        4'd2: acc_b[15:0]  <= ram_rdata;
                        4'd3: acc_a <= trigger[0]
                                     ? acc_a + {ram_rdata, acc_b[15:0]}
                                     : acc_a - {ram_rdata, acc_b[15:0]};
                        default: ;
                    endcase
                    16'h2a05: case (step)
                        4'd0: delta <= ram_rdata;
                        4'd1: acc_a <= {16'd0, ram_rdata} + {16'd0, delta};
                        4'd4: acc_a <= {16'd0, ram_rdata} + {16'd0, delta};
                        default: ;
                    endcase
                    16'h5205, 16'h5a05, 16'hf205: case (step)
                        4'd0: acc_a[15:0]  <= ram_rdata;
                        4'd1: acc_a[31:16] <= ram_rdata;
                        default: ;
                    endcase
                    16'h3b30, 16'h3bb0, 16'h39b0: case (step)
                        4'd0: acc_a[15:0]  <= ram_rdata;   // x0
                        4'd1: acc_a[31:16] <= ram_rdata;
                        4'd2: acc_b[15:0]  <= ram_rdata;   // x1
                        4'd3: acc_b[31:16] <= ram_rdata;
                        4'd4: acc_c[15:0]  <= ram_rdata;   // y0
                        4'd5: acc_c[31:16] <= ram_rdata;
                        4'd6: acc_d[15:0]  <= ram_rdata;   // y1 low
                        default: begin                     // y1 high
                            // Only the differences here; the squares and their
                            // sum are pipelined in C_CALC below.
                            dxr     <= dx32;
                            dyr     <= dy32;
                            dv_den  <= 16'd1;              // idle unit, no div0
                            dv_num  <= 32'd0;
                            dv_rem  <= 17'd0;
                            dv_quot <= 21'd0;
                        end
                    endcase
                    16'h130e, 16'h138e, 16'h330e, 16'h338e: case (step)
                        4'd0: acc_a[15:0]  <= ram_rdata;
                        4'd1: acc_a[31:16] <= ram_rdata;
                        4'd2: acc_b[15:0]  <= ram_rdata;
                        4'd3: acc_b[31:16] <= ram_rdata;
                        4'd4: acc_c[15:0]  <= ram_rdata;
                        4'd5: acc_c[31:16] <= ram_rdata;
                        4'd6: acc_d[15:0]  <= ram_rdata;
                        default: begin
                            // The FULL dword difference, not the >>16 form the
                            // sqrt op uses: MAME subtracts whole dwords here.
                            at_ax     <= dist_dx[31] ? (~dist_dx + 32'd1) : dist_dx;
                            at_ay     <= dist_dy[31] ? (~dist_dy + 32'd1) : dist_dy;
                            at_neg    <= dist_dx[31] ^ dist_dy[31];
                            at_dyneg  <= dist_dy[31];
                            at_dyzero <= (dist_dy == 32'd0);
                            at_lo     <= 9'sd0;  at_hi <= 9'sd63;
                            at_k      <= 6'd0;
                            at_step   <= 3'd0;   at_phase <= 2'd0;
                        end
                    endcase
                    16'h2208, 16'h2288: case (step)
                        4'd0:    acc_a <= {16'd0, ram_rdata};
                        default: begin
                            // read_word into an int: zero extended, so both
                            // operands are non-negative and dy is never < 0.
                            at_ax     <= acc_a;
                            at_ay     <= {16'd0, ram_rdata};
                            at_neg    <= 1'b0;
                            at_dyneg  <= 1'b0;
                            at_dyzero <= (ram_rdata == 16'd0);
                            at_lo     <= 9'sd0;  at_hi <= 9'sd63;
                            at_k      <= 6'd0;
                            at_step   <= 3'd0;   at_phase <= 2'd0;
                        end
                    endcase
                    16'h8100, 16'h8900: case (step)
                        4'd0:    trig_angle <= rd_byte;
                        default: trig_amp   <= rd_byte;
                    endcase
                    16'h6200: case (step)
                        4'd0: ang_cur   <= rd_byte;
                        default: ang_flags <= ram_rdata;
                    endcase
                    16'ha100, 16'ha180, 16'ha900, 16'ha980: case (step)
                        4'd0: begin
                            col_flags[col_slot] <= ram_rdata;
                            col_swap [col_slot] <= cmd_swapf;
                        end
                        4'd1:    col_pos[col_slot][0] <= $signed(ram_rdata);
                        4'd2:    col_pos[col_slot][1] <= $signed(ram_rdata);
                        default: col_pos[col_slot][2] <= $signed(ram_rdata);
                    endcase
                    16'hb100, 16'hb900: case (step)
                        // The pointer is read as a plain word; the base
                        // register supplies the high half.
                        4'd0: hitadr2 <= {cop_hit_baseadr, ram_rdata};
                        4'd1: hb_dx  [0] <= $signed(rd_byte);
                        4'd2: hb_size[0] <= rd_byte;
                        4'd3: hb_dx  [1] <= $signed(rd_byte);
                        4'd4: hb_size[1] <= rd_byte;
                        4'd5: hb_dx  [2] <= $signed(rd_byte);
                        default: hb_size[2] <= rd_byte;
                    endcase
                    16'h42c2, 16'h4aa0: case (step)
                        default: begin
                            // A zero divisor is an error for 0x42c2 but is
                            // silently forced to 1 for 0x4aa0.
                            div_zero <= (ram_rdata == 16'd0) && (trigger == 16'h42c2);
                            dv_den   <= (ram_rdata == 16'd0) ? 16'd1 : ram_rdata;
                            dv_num   <= div_num;
                            dv_rem   <= 17'd0;
                            dv_quot  <= 21'd0;
                            sq_val   <= 32'd0;
                            sq_rem   <= 32'd0;
                            sq_root  <= 16'd0;
                        end
                    endcase
                    default: ;
                    endcase
                    cstate <= C_NEXT;
                end

                C_WR: begin
                    ram_we <= 1'b1;
                    cstate <= C_NEXT;
                end

                C_NEXT: begin
                    if (last_step) cstate <= C_DONE;
                    else begin
                        step   <= step + 4'd1;
                        cstate <= C_RD_ADDR;
                    end
                end

                // ---- 0x7e05 (Raiden DX): tile bank copy -----------------
                C_BANK_WAIT: begin
                    ram_rd <= 1'b1;
                    if (latency == 2'd0) cstate <= C_BANK_TAKE;
                    else                 latency <= latency - 2'd1;
                end

                C_BANK_TAKE: begin
                    ram_rd        <= 1'b0;
                    cop_bank_data <= ea[0] ? ram_rdata[15:8] : ram_rdata[7:0];
                    cop_bank_we   <= 1'b1;
                    cstate        <= C_DONE;
                end

                default: cstate <= C_IDLE;   // C_DONE
            endcase
        end
    end

endmodule
