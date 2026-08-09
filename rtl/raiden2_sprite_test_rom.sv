//==========================================================================
//  Raiden II - synthetic sprite list + tile set for the sprite test
//
//  GENERATED FILE -- do not edit by hand.
//  Produced by tools/make_sprite_test.py.
//
//  Feeds sei252 in place of the game's sprite RAM and the SDRAM sprite
//  ROM, so the renderer can be proved on hardware without r2crypt (the
//  real sprite ROMs arrive encrypted), without SDRAM, and without the COP
//  having built a list.
//
//  Expected picture, top to bottom:
//    row 1  four Fs: plain, flipX, flipY, flipXY
//    row 2  three 2x2 blocks; quadrants must read  1 3  (column-major)
//                                                  2 4
//    row 3  two sprites clipped at the left and top edges (coord wrap)
//    row 4  three overlapping blocks; the FIRST listed must be on top
//    row 5  one 4-wide sprite
//==========================================================================

module raiden2_sprite_test_rom (
    input  logic        clk,
    input  logic [10:0] spr_addr,     // {entry[8:0], word[1:0]}
    output logic [15:0] spr_data,
    input  logic [22:0] rom_addr,     // byte address into the tile set
    output logic [63:0] rom_data
);

    localparam int N_SPRITES = 13;

    logic [15:0] slist [0:51];
    initial begin
        slist[  0] = 16'h0001;   // plain
        slist[  1] = 16'h0001;
        slist[  2] = 16'h0018;
        slist[  3] = 16'h0018;
        slist[  4] = 16'h0801;   // flipX
        slist[  5] = 16'h0001;
        slist[  6] = 16'h0038;
        slist[  7] = 16'h0018;
        slist[  8] = 16'h8001;   // flipY
        slist[  9] = 16'h0001;
        slist[ 10] = 16'h0058;
        slist[ 11] = 16'h0018;
        slist[ 12] = 16'h8801;   // flipXY
        slist[ 13] = 16'h0001;
        slist[ 14] = 16'h0078;
        slist[ 15] = 16'h0018;
        slist[ 16] = 16'h1102;   // 2x2
        slist[ 17] = 16'h0002;
        slist[ 18] = 16'h0018;
        slist[ 19] = 16'h0040;
        slist[ 20] = 16'h1902;   // 2x2 flipX
        slist[ 21] = 16'h0002;
        slist[ 22] = 16'h0058;
        slist[ 23] = 16'h0040;
        slist[ 24] = 16'h9102;   // 2x2 flipY
        slist[ 25] = 16'h0002;
        slist[ 26] = 16'h0098;
        slist[ 27] = 16'h0040;
        slist[ 28] = 16'h0103;   // wrap -X
        slist[ 29] = 16'h0001;
        slist[ 30] = 16'h01F8;
        slist[ 31] = 16'h0070;
        slist[ 32] = 16'h1003;   // wrap -Y
        slist[ 33] = 16'h0001;
        slist[ 34] = 16'h00D8;
        slist[ 35] = 16'h01F8;
        slist[ 36] = 16'h0004;   // pri 0
        slist[ 37] = 16'h0006;
        slist[ 38] = 16'h0028;
        slist[ 39] = 16'h0098;
        slist[ 40] = 16'h0045;   // pri 1
        slist[ 41] = 16'h0007;
        slist[ 42] = 16'h0030;
        slist[ 43] = 16'h00A0;
        slist[ 44] = 16'h0086;   // pri 2
        slist[ 45] = 16'h0008;
        slist[ 46] = 16'h0038;
        slist[ 47] = 16'h00A8;
        slist[ 48] = 16'h0307;   // wide 4x1
        slist[ 49] = 16'h0002;
        slist[ 50] = 16'h0098;
        slist[ 51] = 16'h0098;
    end

    logic [63:0] tiles [0:143];
    initial begin
        tiles[   0] = 64'h0000000000000000;
        tiles[   1] = 64'h0000000000000000;
        tiles[   2] = 64'h0000000000000000;
        tiles[   3] = 64'h0000000000000000;
        tiles[   4] = 64'h0000000000000000;
        tiles[   5] = 64'h0000000000000000;
        tiles[   6] = 64'h0000000000000000;
        tiles[   7] = 64'h0000000000000000;
        tiles[   8] = 64'h0000000000000000;
        tiles[   9] = 64'h0000000000000000;
        tiles[  10] = 64'h0000000000000000;
        tiles[  11] = 64'h0000000000000000;
        tiles[  12] = 64'h0000000000000000;
        tiles[  13] = 64'h0000000000000000;
        tiles[  14] = 64'h0000000000000000;
        tiles[  15] = 64'h0000000000000000;
        tiles[  16] = 64'hFFFFFFFFFFFFFFFF;
        tiles[  17] = 64'hFF2222222222222F;
        tiles[  18] = 64'hFFFFFFFFFFFFFF2F;
        tiles[  19] = 64'hFFFFFFFFFFFFFF2F;
        tiles[  20] = 64'hFFFFFFFFFFFFFF2F;
        tiles[  21] = 64'hFFFFFFF22222222F;
        tiles[  22] = 64'hFFFFFFFFFFFFFF2F;
        tiles[  23] = 64'hFFFFFFFFFFFFFF2F;
        tiles[  24] = 64'hFFFFFFFFFFFFFF2F;
        tiles[  25] = 64'hFFFFFFFFFFFFFF2F;
        tiles[  26] = 64'hFFFFFFFFFFFFFF2F;
        tiles[  27] = 64'hFFFFFFFFFFFFFF2F;
        tiles[  28] = 64'hFFFFFFFFFFFFFF2F;
        tiles[  29] = 64'hFFFFFFFFFFFFFFFF;
        tiles[  30] = 64'hFFFFFFFFFFFFFFFF;
        tiles[  31] = 64'hFFFFFFFFFFFFFFFF;
        tiles[  32] = 64'h3333333333333333;
        tiles[  33] = 64'h3FFFFFFFFFFFFFF3;
        tiles[  34] = 64'h3FFFFFFFFFFFFFF3;
        tiles[  35] = 64'h3FFFFFFFFFFFFFF3;
        tiles[  36] = 64'h3FFFFFFFFFFFFFF3;
        tiles[  37] = 64'h3FFFFFFFFFFFFFF3;
        tiles[  38] = 64'h3FFFFFFFFFFFFFF3;
        tiles[  39] = 64'h3FFFFFFFFFFFFFF3;
        tiles[  40] = 64'h3FFFFFFFFFFFFFF3;
        tiles[  41] = 64'h3FFFFFFFFFFFFFF3;
        tiles[  42] = 64'h3FFFFFFFFFFFFFF3;
        tiles[  43] = 64'h3FFFFFFFFFFFFFF3;
        tiles[  44] = 64'h3FFFFFFFFFFFFFF3;
        tiles[  45] = 64'h3FFFFFFFFFFFFFF3;
        tiles[  46] = 64'h3FFFFFFFFFFFFFF3;
        tiles[  47] = 64'h3333333333333333;
        tiles[  48] = 64'h4444444444444444;
        tiles[  49] = 64'h4FFFFFFFFFFFFFF4;
        tiles[  50] = 64'h4FFFFFFFFFFFFFF4;
        tiles[  51] = 64'h4FFFFFFFFFFFFFF4;
        tiles[  52] = 64'h4FFFFFFFFFFFFFF4;
        tiles[  53] = 64'h4FFFFFFFFFFFFFF4;
        tiles[  54] = 64'h4FFFFFFFFFFFFFF4;
        tiles[  55] = 64'h4FFFFFFFFFFFFFF4;
        tiles[  56] = 64'h4FFFFFFFFFFFFFF4;
        tiles[  57] = 64'h4FFFFFFFFFFFFFF4;
        tiles[  58] = 64'h4FFFFFFFFFFFFFF4;
        tiles[  59] = 64'h4FFFFFFFFFFFFFF4;
        tiles[  60] = 64'h4FFFFFFFFFFFFFF4;
        tiles[  61] = 64'h4FFFFFFFFFFFFFF4;
        tiles[  62] = 64'h4FFFFFFFFFFFFFF4;
        tiles[  63] = 64'h4444444444444444;
        tiles[  64] = 64'h5555555555555555;
        tiles[  65] = 64'h5FFFFFFFFFFFFFF5;
        tiles[  66] = 64'h5FFFFFFFFFFFFFF5;
        tiles[  67] = 64'h5FFFFFFFFFFFFFF5;
        tiles[  68] = 64'h5FFFFFFFFFFFFFF5;
        tiles[  69] = 64'h5FFFFFFFFFFFFFF5;
        tiles[  70] = 64'h5FFFFFFFFFFFFFF5;
        tiles[  71] = 64'h5FFFFFFFFFFFFFF5;
        tiles[  72] = 64'h5FFFFFFFFFFFFFF5;
        tiles[  73] = 64'h5FFFFFFFFFFFFFF5;
        tiles[  74] = 64'h5FFFFFFFFFFFFFF5;
        tiles[  75] = 64'h5FFFFFFFFFFFFFF5;
        tiles[  76] = 64'h5FFFFFFFFFFFFFF5;
        tiles[  77] = 64'h5FFFFFFFFFFFFFF5;
        tiles[  78] = 64'h5FFFFFFFFFFFFFF5;
        tiles[  79] = 64'h5555555555555555;
        tiles[  80] = 64'h6666666666666666;
        tiles[  81] = 64'h6FFFFFFFFFFFFFF6;
        tiles[  82] = 64'h6FFFFFFFFFFFFFF6;
        tiles[  83] = 64'h6FFFFFFFFFFFFFF6;
        tiles[  84] = 64'h6FFFFFFFFFFFFFF6;
        tiles[  85] = 64'h6FFFFFFFFFFFFFF6;
        tiles[  86] = 64'h6FFFFFFFFFFFFFF6;
        tiles[  87] = 64'h6FFFFFFFFFFFFFF6;
        tiles[  88] = 64'h6FFFFFFFFFFFFFF6;
        tiles[  89] = 64'h6FFFFFFFFFFFFFF6;
        tiles[  90] = 64'h6FFFFFFFFFFFFFF6;
        tiles[  91] = 64'h6FFFFFFFFFFFFFF6;
        tiles[  92] = 64'h6FFFFFFFFFFFFFF6;
        tiles[  93] = 64'h6FFFFFFFFFFFFFF6;
        tiles[  94] = 64'h6FFFFFFFFFFFFFF6;
        tiles[  95] = 64'h6666666666666666;
        tiles[  96] = 64'h7777777777777777;
        tiles[  97] = 64'h7777777777777777;
        tiles[  98] = 64'h7777777777777777;
        tiles[  99] = 64'h7777777777777777;
        tiles[ 100] = 64'h7777777777777777;
        tiles[ 101] = 64'h7777777777777777;
        tiles[ 102] = 64'h7777777777777777;
        tiles[ 103] = 64'h7777777777777777;
        tiles[ 104] = 64'h7777777777777777;
        tiles[ 105] = 64'h7777777777777777;
        tiles[ 106] = 64'h7777777777777777;
        tiles[ 107] = 64'h7777777777777777;
        tiles[ 108] = 64'h7777777777777777;
        tiles[ 109] = 64'h7777777777777777;
        tiles[ 110] = 64'h7777777777777777;
        tiles[ 111] = 64'h7777777777777777;
        tiles[ 112] = 64'h9999999999999999;
        tiles[ 113] = 64'h9999999999999999;
        tiles[ 114] = 64'h9999999999999999;
        tiles[ 115] = 64'h9999999999999999;
        tiles[ 116] = 64'h9999999999999999;
        tiles[ 117] = 64'h9999999999999999;
        tiles[ 118] = 64'h9999999999999999;
        tiles[ 119] = 64'h9999999999999999;
        tiles[ 120] = 64'h9999999999999999;
        tiles[ 121] = 64'h9999999999999999;
        tiles[ 122] = 64'h9999999999999999;
        tiles[ 123] = 64'h9999999999999999;
        tiles[ 124] = 64'h9999999999999999;
        tiles[ 125] = 64'h9999999999999999;
        tiles[ 126] = 64'h9999999999999999;
        tiles[ 127] = 64'h9999999999999999;
        tiles[ 128] = 64'hBBBBBBBBBBBBBBBB;
        tiles[ 129] = 64'hBBBBBBBBBBBBBBBB;
        tiles[ 130] = 64'hBBBBBBBBBBBBBBBB;
        tiles[ 131] = 64'hBBBBBBBBBBBBBBBB;
        tiles[ 132] = 64'hBBBBBBBBBBBBBBBB;
        tiles[ 133] = 64'hBBBBBBBBBBBBBBBB;
        tiles[ 134] = 64'hBBBBBBBBBBBBBBBB;
        tiles[ 135] = 64'hBBBBBBBBBBBBBBBB;
        tiles[ 136] = 64'hBBBBBBBBBBBBBBBB;
        tiles[ 137] = 64'hBBBBBBBBBBBBBBBB;
        tiles[ 138] = 64'hBBBBBBBBBBBBBBBB;
        tiles[ 139] = 64'hBBBBBBBBBBBBBBBB;
        tiles[ 140] = 64'hBBBBBBBBBBBBBBBB;
        tiles[ 141] = 64'hBBBBBBBBBBBBBBBB;
        tiles[ 142] = 64'hBBBBBBBBBBBBBBBB;
        tiles[ 143] = 64'hBBBBBBBBBBBBBBBB;
    end

    // Entries past the list read back a zero tile code, which sei252
    // treats as an empty slot -- exactly how the real list terminates.
    wire [8:0] entry = spr_addr[10:2];
    always_ff @(posedge clk)
        spr_data <= (entry < N_SPRITES) ? slist[{entry[6:0], spr_addr[1:0]}]
                                       : 16'd0;

    // One 8-byte tile row per request, little-endian, matching the
    // order sdram.sv assembles ch2_dout in.
    wire [9:0] ta_full = rom_addr[12:3];
    wire [7:0] ta = ta_full[7:0];
    always_ff @(posedge clk)
        rom_data <= (ta_full < 144) ? tiles[ta] : 64'd0;

endmodule
