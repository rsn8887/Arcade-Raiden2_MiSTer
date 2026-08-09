//==========================================================================
//  Raiden II sprite ROM decryption, in hardware
//
//  GENERATED FILE -- do not edit by hand.
//  Produced by tools/make_r2crypt_rtl.py from tools/r2crypt.py, which is
//  itself a port of MAME src/mame/seibu/r2crypt.cpp
//  (Andreas Naive, Olivier Galibert, BSD-3-Clause) and the
//  seibu_partial_carry_sum helper from src/mame/seibu/seibu_helper.cpp.
//
//  Pure function of (dword index, data word) -- no state carried between
//  words -- so it sits in the ROM download path and decrypts on the fly.
//  Fixed 3-clock latency, one dword per clock, never stalls.
//
//  Verified against the Python oracle by sim/tb_r2crypt.cpp.
//==========================================================================

module raiden2_r2crypt (
    input  logic        clk,
    input  logic [20:0] idx,        // dword index within the sprite region
    input  logic [31:0] din,        // encrypted
    input  logic        in_valid,
    output logic [31:0] dout,       // plain, 3 clocks later
    output logic        out_valid
);

    localparam logic [31:0] PRE_XOR    = 32'h60860000;
    localparam logic [31:0] POST_XOR   = 32'h0F488000;
    localparam logic [31:0] CARRY_MASK = 32'h176C91A8;

    //---------------- lookup tables ----------------
    logic [4:0] rot_tab [0:511];
    initial begin
        rot_tab[  0] = 5'h11; rot_tab[  1] = 5'h17; rot_tab[  2] = 5'h0D; rot_tab[  3] = 5'h03; rot_tab[  4] = 5'h17; rot_tab[  5] = 5'h1F; rot_tab[  6] = 5'h08; rot_tab[  7] = 5'h1A;
        rot_tab[  8] = 5'h0F; rot_tab[  9] = 5'h04; rot_tab[ 10] = 5'h1E; rot_tab[ 11] = 5'h13; rot_tab[ 12] = 5'h19; rot_tab[ 13] = 5'h0E; rot_tab[ 14] = 5'h0E; rot_tab[ 15] = 5'h05;
        rot_tab[ 16] = 5'h06; rot_tab[ 17] = 5'h07; rot_tab[ 18] = 5'h08; rot_tab[ 19] = 5'h08; rot_tab[ 20] = 5'h0D; rot_tab[ 21] = 5'h18; rot_tab[ 22] = 5'h11; rot_tab[ 23] = 5'h1A;
        rot_tab[ 24] = 5'h0B; rot_tab[ 25] = 5'h06; rot_tab[ 26] = 5'h12; rot_tab[ 27] = 5'h0C; rot_tab[ 28] = 5'h1F; rot_tab[ 29] = 5'h0B; rot_tab[ 30] = 5'h1C; rot_tab[ 31] = 5'h19;
        rot_tab[ 32] = 5'h00; rot_tab[ 33] = 5'h1B; rot_tab[ 34] = 5'h0C; rot_tab[ 35] = 5'h09; rot_tab[ 36] = 5'h1D; rot_tab[ 37] = 5'h18; rot_tab[ 38] = 5'h1A; rot_tab[ 39] = 5'h16;
        rot_tab[ 40] = 5'h1A; rot_tab[ 41] = 5'h08; rot_tab[ 42] = 5'h03; rot_tab[ 43] = 5'h04; rot_tab[ 44] = 5'h0F; rot_tab[ 45] = 5'h1D; rot_tab[ 46] = 5'h16; rot_tab[ 47] = 5'h07;
        rot_tab[ 48] = 5'h1A; rot_tab[ 49] = 5'h12; rot_tab[ 50] = 5'h01; rot_tab[ 51] = 5'h0B; rot_tab[ 52] = 5'h00; rot_tab[ 53] = 5'h0F; rot_tab[ 54] = 5'h1E; rot_tab[ 55] = 5'h10;
        rot_tab[ 56] = 5'h09; rot_tab[ 57] = 5'h0F; rot_tab[ 58] = 5'h10; rot_tab[ 59] = 5'h09; rot_tab[ 60] = 5'h0A; rot_tab[ 61] = 5'h1C; rot_tab[ 62] = 5'h0D; rot_tab[ 63] = 5'h08;
        rot_tab[ 64] = 5'h06; rot_tab[ 65] = 5'h1A; rot_tab[ 66] = 5'h06; rot_tab[ 67] = 5'h02; rot_tab[ 68] = 5'h11; rot_tab[ 69] = 5'h1E; rot_tab[ 70] = 5'h0C; rot_tab[ 71] = 5'h1C;
        rot_tab[ 72] = 5'h11; rot_tab[ 73] = 5'h0F; rot_tab[ 74] = 5'h19; rot_tab[ 75] = 5'h0A; rot_tab[ 76] = 5'h16; rot_tab[ 77] = 5'h14; rot_tab[ 78] = 5'h18; rot_tab[ 79] = 5'h11;
        rot_tab[ 80] = 5'h0B; rot_tab[ 81] = 5'h0D; rot_tab[ 82] = 5'h1C; rot_tab[ 83] = 5'h1F; rot_tab[ 84] = 5'h0D; rot_tab[ 85] = 5'h1F; rot_tab[ 86] = 5'h0D; rot_tab[ 87] = 5'h19;
        rot_tab[ 88] = 5'h0D; rot_tab[ 89] = 5'h04; rot_tab[ 90] = 5'h19; rot_tab[ 91] = 5'h0F; rot_tab[ 92] = 5'h06; rot_tab[ 93] = 5'h13; rot_tab[ 94] = 5'h0C; rot_tab[ 95] = 5'h1B;
        rot_tab[ 96] = 5'h1F; rot_tab[ 97] = 5'h12; rot_tab[ 98] = 5'h15; rot_tab[ 99] = 5'h1A; rot_tab[100] = 5'h04; rot_tab[101] = 5'h02; rot_tab[102] = 5'h06; rot_tab[103] = 5'h03;
        rot_tab[104] = 5'h0A; rot_tab[105] = 5'h0D; rot_tab[106] = 5'h12; rot_tab[107] = 5'h09; rot_tab[108] = 5'h17; rot_tab[109] = 5'h1D; rot_tab[110] = 5'h12; rot_tab[111] = 5'h10;
        rot_tab[112] = 5'h05; rot_tab[113] = 5'h07; rot_tab[114] = 5'h03; rot_tab[115] = 5'h00; rot_tab[116] = 5'h14; rot_tab[117] = 5'h07; rot_tab[118] = 5'h14; rot_tab[119] = 5'h1A;
        rot_tab[120] = 5'h1C; rot_tab[121] = 5'h0A; rot_tab[122] = 5'h10; rot_tab[123] = 5'h0F; rot_tab[124] = 5'h0B; rot_tab[125] = 5'h0C; rot_tab[126] = 5'h08; rot_tab[127] = 5'h0F;
        rot_tab[128] = 5'h07; rot_tab[129] = 5'h00; rot_tab[130] = 5'h13; rot_tab[131] = 5'h1C; rot_tab[132] = 5'h04; rot_tab[133] = 5'h15; rot_tab[134] = 5'h0E; rot_tab[135] = 5'h02;
        rot_tab[136] = 5'h17; rot_tab[137] = 5'h17; rot_tab[138] = 5'h00; rot_tab[139] = 5'h03; rot_tab[140] = 5'h18; rot_tab[141] = 5'h00; rot_tab[142] = 5'h02; rot_tab[143] = 5'h13;
        rot_tab[144] = 5'h14; rot_tab[145] = 5'h0C; rot_tab[146] = 5'h01; rot_tab[147] = 5'h0A; rot_tab[148] = 5'h15; rot_tab[149] = 5'h0B; rot_tab[150] = 5'h0A; rot_tab[151] = 5'h1C;
        rot_tab[152] = 5'h1B; rot_tab[153] = 5'h06; rot_tab[154] = 5'h17; rot_tab[155] = 5'h1D; rot_tab[156] = 5'h11; rot_tab[157] = 5'h1F; rot_tab[158] = 5'h10; rot_tab[159] = 5'h04;
        rot_tab[160] = 5'h1A; rot_tab[161] = 5'h01; rot_tab[162] = 5'h1B; rot_tab[163] = 5'h13; rot_tab[164] = 5'h03; rot_tab[165] = 5'h09; rot_tab[166] = 5'h09; rot_tab[167] = 5'h0F;
        rot_tab[168] = 5'h0D; rot_tab[169] = 5'h03; rot_tab[170] = 5'h15; rot_tab[171] = 5'h1C; rot_tab[172] = 5'h04; rot_tab[173] = 5'h06; rot_tab[174] = 5'h06; rot_tab[175] = 5'h0B;
        rot_tab[176] = 5'h04; rot_tab[177] = 5'h0A; rot_tab[178] = 5'h1F; rot_tab[179] = 5'h16; rot_tab[180] = 5'h11; rot_tab[181] = 5'h0A; rot_tab[182] = 5'h05; rot_tab[183] = 5'h05;
        rot_tab[184] = 5'h0C; rot_tab[185] = 5'h1C; rot_tab[186] = 5'h10; rot_tab[187] = 5'h0C; rot_tab[188] = 5'h11; rot_tab[189] = 5'h04; rot_tab[190] = 5'h10; rot_tab[191] = 5'h1A;
        rot_tab[192] = 5'h06; rot_tab[193] = 5'h10; rot_tab[194] = 5'h19; rot_tab[195] = 5'h06; rot_tab[196] = 5'h15; rot_tab[197] = 5'h0F; rot_tab[198] = 5'h11; rot_tab[199] = 5'h01;
        rot_tab[200] = 5'h10; rot_tab[201] = 5'h0C; rot_tab[202] = 5'h1D; rot_tab[203] = 5'h05; rot_tab[204] = 5'h1F; rot_tab[205] = 5'h05; rot_tab[206] = 5'h12; rot_tab[207] = 5'h16;
        rot_tab[208] = 5'h02; rot_tab[209] = 5'h12; rot_tab[210] = 5'h14; rot_tab[211] = 5'h0D; rot_tab[212] = 5'h14; rot_tab[213] = 5'h0F; rot_tab[214] = 5'h04; rot_tab[215] = 5'h07;
        rot_tab[216] = 5'h13; rot_tab[217] = 5'h01; rot_tab[218] = 5'h11; rot_tab[219] = 5'h1C; rot_tab[220] = 5'h1C; rot_tab[221] = 5'h1D; rot_tab[222] = 5'h0E; rot_tab[223] = 5'h06;
        rot_tab[224] = 5'h1D; rot_tab[225] = 5'h13; rot_tab[226] = 5'h10; rot_tab[227] = 5'h06; rot_tab[228] = 5'h0F; rot_tab[229] = 5'h02; rot_tab[230] = 5'h12; rot_tab[231] = 5'h10;
        rot_tab[232] = 5'h1E; rot_tab[233] = 5'h0C; rot_tab[234] = 5'h17; rot_tab[235] = 5'h15; rot_tab[236] = 5'h0B; rot_tab[237] = 5'h1F; rot_tab[238] = 5'h01; rot_tab[239] = 5'h19;
        rot_tab[240] = 5'h02; rot_tab[241] = 5'h01; rot_tab[242] = 5'h07; rot_tab[243] = 5'h1D; rot_tab[244] = 5'h13; rot_tab[245] = 5'h19; rot_tab[246] = 5'h0F; rot_tab[247] = 5'h0F;
        rot_tab[248] = 5'h10; rot_tab[249] = 5'h03; rot_tab[250] = 5'h1E; rot_tab[251] = 5'h03; rot_tab[252] = 5'h0D; rot_tab[253] = 5'h0A; rot_tab[254] = 5'h0C; rot_tab[255] = 5'h0D;
        rot_tab[256] = 5'h16; rot_tab[257] = 5'h1F; rot_tab[258] = 5'h16; rot_tab[259] = 5'h1A; rot_tab[260] = 5'h1C; rot_tab[261] = 5'h16; rot_tab[262] = 5'h01; rot_tab[263] = 5'h03;
        rot_tab[264] = 5'h01; rot_tab[265] = 5'h08; rot_tab[266] = 5'h14; rot_tab[267] = 5'h19; rot_tab[268] = 5'h03; rot_tab[269] = 5'h1E; rot_tab[270] = 5'h08; rot_tab[271] = 5'h02;
        rot_tab[272] = 5'h02; rot_tab[273] = 5'h1D; rot_tab[274] = 5'h15; rot_tab[275] = 5'h00; rot_tab[276] = 5'h09; rot_tab[277] = 5'h1D; rot_tab[278] = 5'h03; rot_tab[279] = 5'h11;
        rot_tab[280] = 5'h11; rot_tab[281] = 5'h0B; rot_tab[282] = 5'h1B; rot_tab[283] = 5'h14; rot_tab[284] = 5'h01; rot_tab[285] = 5'h1E; rot_tab[286] = 5'h11; rot_tab[287] = 5'h12;
        rot_tab[288] = 5'h1D; rot_tab[289] = 5'h06; rot_tab[290] = 5'h0B; rot_tab[291] = 5'h13; rot_tab[292] = 5'h1E; rot_tab[293] = 5'h16; rot_tab[294] = 5'h0D; rot_tab[295] = 5'h10;
        rot_tab[296] = 5'h11; rot_tab[297] = 5'h1F; rot_tab[298] = 5'h1C; rot_tab[299] = 5'h15; rot_tab[300] = 5'h0D; rot_tab[301] = 5'h1A; rot_tab[302] = 5'h13; rot_tab[303] = 5'h1F;
        rot_tab[304] = 5'h0E; rot_tab[305] = 5'h05; rot_tab[306] = 5'h10; rot_tab[307] = 5'h06; rot_tab[308] = 5'h0D; rot_tab[309] = 5'h1C; rot_tab[310] = 5'h07; rot_tab[311] = 5'h19;
        rot_tab[312] = 5'h06; rot_tab[313] = 5'h1D; rot_tab[314] = 5'h11; rot_tab[315] = 5'h00; rot_tab[316] = 5'h1C; rot_tab[317] = 5'h05; rot_tab[318] = 5'h0B; rot_tab[319] = 5'h1D;
        rot_tab[320] = 5'h1C; rot_tab[321] = 5'h06; rot_tab[322] = 5'h05; rot_tab[323] = 5'h1D; rot_tab[324] = 5'h00; rot_tab[325] = 5'h13; rot_tab[326] = 5'h00; rot_tab[327] = 5'h12;
        rot_tab[328] = 5'h1B; rot_tab[329] = 5'h17; rot_tab[330] = 5'h1A; rot_tab[331] = 5'h1B; rot_tab[332] = 5'h17; rot_tab[333] = 5'h1C; rot_tab[334] = 5'h16; rot_tab[335] = 5'h0A;
        rot_tab[336] = 5'h11; rot_tab[337] = 5'h15; rot_tab[338] = 5'h0F; rot_tab[339] = 5'h0B; rot_tab[340] = 5'h0F; rot_tab[341] = 5'h07; rot_tab[342] = 5'h0E; rot_tab[343] = 5'h04;
        rot_tab[344] = 5'h13; rot_tab[345] = 5'h00; rot_tab[346] = 5'h1C; rot_tab[347] = 5'h05; rot_tab[348] = 5'h16; rot_tab[349] = 5'h00; rot_tab[350] = 5'h1A; rot_tab[351] = 5'h04;
        rot_tab[352] = 5'h17; rot_tab[353] = 5'h04; rot_tab[354] = 5'h08; rot_tab[355] = 5'h1B; rot_tab[356] = 5'h05; rot_tab[357] = 5'h12; rot_tab[358] = 5'h1D; rot_tab[359] = 5'h0D;
        rot_tab[360] = 5'h02; rot_tab[361] = 5'h16; rot_tab[362] = 5'h12; rot_tab[363] = 5'h0E; rot_tab[364] = 5'h06; rot_tab[365] = 5'h08; rot_tab[366] = 5'h14; rot_tab[367] = 5'h07;
        rot_tab[368] = 5'h0E; rot_tab[369] = 5'h0F; rot_tab[370] = 5'h15; rot_tab[371] = 5'h13; rot_tab[372] = 5'h12; rot_tab[373] = 5'h00; rot_tab[374] = 5'h1D; rot_tab[375] = 5'h16;
        rot_tab[376] = 5'h1B; rot_tab[377] = 5'h18; rot_tab[378] = 5'h1F; rot_tab[379] = 5'h05; rot_tab[380] = 5'h12; rot_tab[381] = 5'h13; rot_tab[382] = 5'h01; rot_tab[383] = 5'h0C;
        rot_tab[384] = 5'h12; rot_tab[385] = 5'h04; rot_tab[386] = 5'h19; rot_tab[387] = 5'h13; rot_tab[388] = 5'h12; rot_tab[389] = 5'h15; rot_tab[390] = 5'h07; rot_tab[391] = 5'h06;
        rot_tab[392] = 5'h0A; rot_tab[393] = 5'h00; rot_tab[394] = 5'h09; rot_tab[395] = 5'h14; rot_tab[396] = 5'h1E; rot_tab[397] = 5'h03; rot_tab[398] = 5'h10; rot_tab[399] = 5'h1B;
        rot_tab[400] = 5'h08; rot_tab[401] = 5'h1A; rot_tab[402] = 5'h07; rot_tab[403] = 5'h02; rot_tab[404] = 5'h1B; rot_tab[405] = 5'h0D; rot_tab[406] = 5'h18; rot_tab[407] = 5'h13;
        rot_tab[408] = 5'h02; rot_tab[409] = 5'h07; rot_tab[410] = 5'h1E; rot_tab[411] = 5'h05; rot_tab[412] = 5'h15; rot_tab[413] = 5'h02; rot_tab[414] = 5'h06; rot_tab[415] = 5'h18;
        rot_tab[416] = 5'h12; rot_tab[417] = 5'h09; rot_tab[418] = 5'h1C; rot_tab[419] = 5'h07; rot_tab[420] = 5'h0B; rot_tab[421] = 5'h02; rot_tab[422] = 5'h03; rot_tab[423] = 5'h00;
        rot_tab[424] = 5'h18; rot_tab[425] = 5'h18; rot_tab[426] = 5'h03; rot_tab[427] = 5'h0F; rot_tab[428] = 5'h02; rot_tab[429] = 5'h0F; rot_tab[430] = 5'h10; rot_tab[431] = 5'h09;
        rot_tab[432] = 5'h05; rot_tab[433] = 5'h18; rot_tab[434] = 5'h08; rot_tab[435] = 5'h1B; rot_tab[436] = 5'h0D; rot_tab[437] = 5'h10; rot_tab[438] = 5'h03; rot_tab[439] = 5'h00;
        rot_tab[440] = 5'h0C; rot_tab[441] = 5'h14; rot_tab[442] = 5'h1D; rot_tab[443] = 5'h08; rot_tab[444] = 5'h02; rot_tab[445] = 5'h10; rot_tab[446] = 5'h0B; rot_tab[447] = 5'h0C;
        rot_tab[448] = 5'h00; rot_tab[449] = 5'h0D; rot_tab[450] = 5'h0D; rot_tab[451] = 5'h0A; rot_tab[452] = 5'h06; rot_tab[453] = 5'h1C; rot_tab[454] = 5'h09; rot_tab[455] = 5'h19;
        rot_tab[456] = 5'h1B; rot_tab[457] = 5'h14; rot_tab[458] = 5'h18; rot_tab[459] = 5'h0F; rot_tab[460] = 5'h02; rot_tab[461] = 5'h07; rot_tab[462] = 5'h05; rot_tab[463] = 5'h04;
        rot_tab[464] = 5'h1C; rot_tab[465] = 5'h15; rot_tab[466] = 5'h18; rot_tab[467] = 5'h00; rot_tab[468] = 5'h0B; rot_tab[469] = 5'h10; rot_tab[470] = 5'h19; rot_tab[471] = 5'h1C;
        rot_tab[472] = 5'h1B; rot_tab[473] = 5'h08; rot_tab[474] = 5'h1D; rot_tab[475] = 5'h12; rot_tab[476] = 5'h17; rot_tab[477] = 5'h1D; rot_tab[478] = 5'h0C; rot_tab[479] = 5'h01;
        rot_tab[480] = 5'h03; rot_tab[481] = 5'h0D; rot_tab[482] = 5'h03; rot_tab[483] = 5'h0D; rot_tab[484] = 5'h15; rot_tab[485] = 5'h0E; rot_tab[486] = 5'h16; rot_tab[487] = 5'h08;
        rot_tab[488] = 5'h05; rot_tab[489] = 5'h11; rot_tab[490] = 5'h1F; rot_tab[491] = 5'h03; rot_tab[492] = 5'h16; rot_tab[493] = 5'h03; rot_tab[494] = 5'h0F; rot_tab[495] = 5'h10;
        rot_tab[496] = 5'h08; rot_tab[497] = 5'h19; rot_tab[498] = 5'h18; rot_tab[499] = 5'h15; rot_tab[500] = 5'h1F; rot_tab[501] = 5'h05; rot_tab[502] = 5'h00; rot_tab[503] = 5'h09;
        rot_tab[504] = 5'h0E; rot_tab[505] = 5'h05; rot_tab[506] = 5'h16; rot_tab[507] = 5'h1B; rot_tab[508] = 5'h01; rot_tab[509] = 5'h08; rot_tab[510] = 5'h08; rot_tab[511] = 5'h1F;
    end

    logic [4:0] x5_tab [0:255];
    initial begin
        x5_tab[  0] = 5'h08; x5_tab[  1] = 5'h09; x5_tab[  2] = 5'h1F; x5_tab[  3] = 5'h0F; x5_tab[  4] = 5'h09; x5_tab[  5] = 5'h09; x5_tab[  6] = 5'h0B; x5_tab[  7] = 5'h1D;
        x5_tab[  8] = 5'h06; x5_tab[  9] = 5'h13; x5_tab[ 10] = 5'h02; x5_tab[ 11] = 5'h15; x5_tab[ 12] = 5'h02; x5_tab[ 13] = 5'h0C; x5_tab[ 14] = 5'h0D; x5_tab[ 15] = 5'h19;
        x5_tab[ 16] = 5'h03; x5_tab[ 17] = 5'h13; x5_tab[ 18] = 5'h0C; x5_tab[ 19] = 5'h1F; x5_tab[ 20] = 5'h1A; x5_tab[ 21] = 5'h18; x5_tab[ 22] = 5'h17; x5_tab[ 23] = 5'h10;
        x5_tab[ 24] = 5'h0A; x5_tab[ 25] = 5'h19; x5_tab[ 26] = 5'h15; x5_tab[ 27] = 5'h04; x5_tab[ 28] = 5'h1F; x5_tab[ 29] = 5'h11; x5_tab[ 30] = 5'h1C; x5_tab[ 31] = 5'h02;
        x5_tab[ 32] = 5'h0E; x5_tab[ 33] = 5'h08; x5_tab[ 34] = 5'h06; x5_tab[ 35] = 5'h0A; x5_tab[ 36] = 5'h07; x5_tab[ 37] = 5'h1C; x5_tab[ 38] = 5'h10; x5_tab[ 39] = 5'h04;
        x5_tab[ 40] = 5'h11; x5_tab[ 41] = 5'h0C; x5_tab[ 42] = 5'h0A; x5_tab[ 43] = 5'h19; x5_tab[ 44] = 5'h0A; x5_tab[ 45] = 5'h04; x5_tab[ 46] = 5'h17; x5_tab[ 47] = 5'h07;
        x5_tab[ 48] = 5'h16; x5_tab[ 49] = 5'h1B; x5_tab[ 50] = 5'h1D; x5_tab[ 51] = 5'h15; x5_tab[ 52] = 5'h1D; x5_tab[ 53] = 5'h13; x5_tab[ 54] = 5'h0E; x5_tab[ 55] = 5'h03;
        x5_tab[ 56] = 5'h1A; x5_tab[ 57] = 5'h11; x5_tab[ 58] = 5'h14; x5_tab[ 59] = 5'h14; x5_tab[ 60] = 5'h03; x5_tab[ 61] = 5'h18; x5_tab[ 62] = 5'h07; x5_tab[ 63] = 5'h03;
        x5_tab[ 64] = 5'h08; x5_tab[ 65] = 5'h1A; x5_tab[ 66] = 5'h02; x5_tab[ 67] = 5'h0F; x5_tab[ 68] = 5'h0B; x5_tab[ 69] = 5'h11; x5_tab[ 70] = 5'h1C; x5_tab[ 71] = 5'h05;
        x5_tab[ 72] = 5'h19; x5_tab[ 73] = 5'h1D; x5_tab[ 74] = 5'h05; x5_tab[ 75] = 5'h01; x5_tab[ 76] = 5'h1F; x5_tab[ 77] = 5'h1C; x5_tab[ 78] = 5'h1D; x5_tab[ 79] = 5'h07;
        x5_tab[ 80] = 5'h07; x5_tab[ 81] = 5'h0C; x5_tab[ 82] = 5'h02; x5_tab[ 83] = 5'h16; x5_tab[ 84] = 5'h0E; x5_tab[ 85] = 5'h06; x5_tab[ 86] = 5'h0B; x5_tab[ 87] = 5'h07;
        x5_tab[ 88] = 5'h01; x5_tab[ 89] = 5'h1A; x5_tab[ 90] = 5'h09; x5_tab[ 91] = 5'h0E; x5_tab[ 92] = 5'h0E; x5_tab[ 93] = 5'h07; x5_tab[ 94] = 5'h0E; x5_tab[ 95] = 5'h15;
        x5_tab[ 96] = 5'h01; x5_tab[ 97] = 5'h16; x5_tab[ 98] = 5'h13; x5_tab[ 99] = 5'h15; x5_tab[100] = 5'h14; x5_tab[101] = 5'h07; x5_tab[102] = 5'h0C; x5_tab[103] = 5'h1F;
        x5_tab[104] = 5'h1F; x5_tab[105] = 5'h19; x5_tab[106] = 5'h17; x5_tab[107] = 5'h12; x5_tab[108] = 5'h19; x5_tab[109] = 5'h17; x5_tab[110] = 5'h0A; x5_tab[111] = 5'h1F;
        x5_tab[112] = 5'h0C; x5_tab[113] = 5'h16; x5_tab[114] = 5'h15; x5_tab[115] = 5'h1E; x5_tab[116] = 5'h05; x5_tab[117] = 5'h14; x5_tab[118] = 5'h05; x5_tab[119] = 5'h1C;
        x5_tab[120] = 5'h0B; x5_tab[121] = 5'h0D; x5_tab[122] = 5'h0C; x5_tab[123] = 5'h0A; x5_tab[124] = 5'h05; x5_tab[125] = 5'h09; x5_tab[126] = 5'h14; x5_tab[127] = 5'h02;
        x5_tab[128] = 5'h10; x5_tab[129] = 5'h02; x5_tab[130] = 5'h13; x5_tab[131] = 5'h05; x5_tab[132] = 5'h12; x5_tab[133] = 5'h17; x5_tab[134] = 5'h03; x5_tab[135] = 5'h0B;
        x5_tab[136] = 5'h1B; x5_tab[137] = 5'h06; x5_tab[138] = 5'h15; x5_tab[139] = 5'h0B; x5_tab[140] = 5'h01; x5_tab[141] = 5'h0B; x5_tab[142] = 5'h1B; x5_tab[143] = 5'h09;
        x5_tab[144] = 5'h10; x5_tab[145] = 5'h0A; x5_tab[146] = 5'h1E; x5_tab[147] = 5'h09; x5_tab[148] = 5'h08; x5_tab[149] = 5'h0A; x5_tab[150] = 5'h04; x5_tab[151] = 5'h13;
        x5_tab[152] = 5'h04; x5_tab[153] = 5'h12; x5_tab[154] = 5'h04; x5_tab[155] = 5'h0F; x5_tab[156] = 5'h0B; x5_tab[157] = 5'h0C; x5_tab[158] = 5'h06; x5_tab[159] = 5'h07;
        x5_tab[160] = 5'h03; x5_tab[161] = 5'h18; x5_tab[162] = 5'h00; x5_tab[163] = 5'h1E; x5_tab[164] = 5'h17; x5_tab[165] = 5'h00; x5_tab[166] = 5'h16; x5_tab[167] = 5'h08;
        x5_tab[168] = 5'h0D; x5_tab[169] = 5'h1C; x5_tab[170] = 5'h09; x5_tab[171] = 5'h07; x5_tab[172] = 5'h17; x5_tab[173] = 5'h18; x5_tab[174] = 5'h0B; x5_tab[175] = 5'h0D;
        x5_tab[176] = 5'h11; x5_tab[177] = 5'h0F; x5_tab[178] = 5'h14; x5_tab[179] = 5'h1E; x5_tab[180] = 5'h1A; x5_tab[181] = 5'h1B; x5_tab[182] = 5'h09; x5_tab[183] = 5'h15;
        x5_tab[184] = 5'h03; x5_tab[185] = 5'h07; x5_tab[186] = 5'h12; x5_tab[187] = 5'h16; x5_tab[188] = 5'h15; x5_tab[189] = 5'h11; x5_tab[190] = 5'h16; x5_tab[191] = 5'h1E;
        x5_tab[192] = 5'h14; x5_tab[193] = 5'h15; x5_tab[194] = 5'h00; x5_tab[195] = 5'h05; x5_tab[196] = 5'h15; x5_tab[197] = 5'h18; x5_tab[198] = 5'h18; x5_tab[199] = 5'h12;
        x5_tab[200] = 5'h18; x5_tab[201] = 5'h1E; x5_tab[202] = 5'h06; x5_tab[203] = 5'h06; x5_tab[204] = 5'h0C; x5_tab[205] = 5'h1A; x5_tab[206] = 5'h04; x5_tab[207] = 5'h0B;
        x5_tab[208] = 5'h05; x5_tab[209] = 5'h08; x5_tab[210] = 5'h04; x5_tab[211] = 5'h1F; x5_tab[212] = 5'h0C; x5_tab[213] = 5'h08; x5_tab[214] = 5'h0A; x5_tab[215] = 5'h1F;
        x5_tab[216] = 5'h1A; x5_tab[217] = 5'h16; x5_tab[218] = 5'h0E; x5_tab[219] = 5'h1E; x5_tab[220] = 5'h16; x5_tab[221] = 5'h18; x5_tab[222] = 5'h18; x5_tab[223] = 5'h05;
        x5_tab[224] = 5'h00; x5_tab[225] = 5'h1A; x5_tab[226] = 5'h05; x5_tab[227] = 5'h15; x5_tab[228] = 5'h19; x5_tab[229] = 5'h10; x5_tab[230] = 5'h03; x5_tab[231] = 5'h0E;
        x5_tab[232] = 5'h10; x5_tab[233] = 5'h1C; x5_tab[234] = 5'h0A; x5_tab[235] = 5'h18; x5_tab[236] = 5'h00; x5_tab[237] = 5'h16; x5_tab[238] = 5'h0B; x5_tab[239] = 5'h05;
        x5_tab[240] = 5'h05; x5_tab[241] = 5'h15; x5_tab[242] = 5'h11; x5_tab[243] = 5'h0A; x5_tab[244] = 5'h1C; x5_tab[245] = 5'h00; x5_tab[246] = 5'h1E; x5_tab[247] = 5'h1F;
        x5_tab[248] = 5'h17; x5_tab[249] = 5'h12; x5_tab[250] = 5'h0A; x5_tab[251] = 5'h1C; x5_tab[252] = 5'h07; x5_tab[253] = 5'h04; x5_tab[254] = 5'h1F; x5_tab[255] = 5'h1A;
    end

    logic [10:0] x11_tab [0:255];
    initial begin
        x11_tab[  0] = 11'h347; x11_tab[  1] = 11'h0F2; x11_tab[  2] = 11'h182; x11_tab[  3] = 11'h58F; x11_tab[  4] = 11'h1F4; x11_tab[  5] = 11'h42C; x11_tab[  6] = 11'h407; x11_tab[  7] = 11'h5F0;
        x11_tab[  8] = 11'h6DF; x11_tab[  9] = 11'h2DB; x11_tab[ 10] = 11'h585; x11_tab[ 11] = 11'h5FE; x11_tab[ 12] = 11'h394; x11_tab[ 13] = 11'h542; x11_tab[ 14] = 11'h3E8; x11_tab[ 15] = 11'h574;
        x11_tab[ 16] = 11'h4EA; x11_tab[ 17] = 11'h6D3; x11_tab[ 18] = 11'h6B7; x11_tab[ 19] = 11'h65B; x11_tab[ 20] = 11'h324; x11_tab[ 21] = 11'h143; x11_tab[ 22] = 11'h22A; x11_tab[ 23] = 11'h11D;
        x11_tab[ 24] = 11'h124; x11_tab[ 25] = 11'h365; x11_tab[ 26] = 11'h7CA; x11_tab[ 27] = 11'h3D6; x11_tab[ 28] = 11'h1D2; x11_tab[ 29] = 11'h7CD; x11_tab[ 30] = 11'h6B1; x11_tab[ 31] = 11'h4F1;
        x11_tab[ 32] = 11'h1DE; x11_tab[ 33] = 11'h674; x11_tab[ 34] = 11'h685; x11_tab[ 35] = 11'h779; x11_tab[ 36] = 11'h264; x11_tab[ 37] = 11'h6D8; x11_tab[ 38] = 11'h379; x11_tab[ 39] = 11'h7CE;
        x11_tab[ 40] = 11'h201; x11_tab[ 41] = 11'h73B; x11_tab[ 42] = 11'h5C9; x11_tab[ 43] = 11'h025; x11_tab[ 44] = 11'h338; x11_tab[ 45] = 11'h4B2; x11_tab[ 46] = 11'h697; x11_tab[ 47] = 11'h567;
        x11_tab[ 48] = 11'h312; x11_tab[ 49] = 11'h04E; x11_tab[ 50] = 11'h78D; x11_tab[ 51] = 11'h492; x11_tab[ 52] = 11'h044; x11_tab[ 53] = 11'h203; x11_tab[ 54] = 11'h437; x11_tab[ 55] = 11'h04B;
        x11_tab[ 56] = 11'h729; x11_tab[ 57] = 11'h197; x11_tab[ 58] = 11'h6E2; x11_tab[ 59] = 11'h552; x11_tab[ 60] = 11'h517; x11_tab[ 61] = 11'h3C9; x11_tab[ 62] = 11'h09C; x11_tab[ 63] = 11'h3DE;
        x11_tab[ 64] = 11'h2F8; x11_tab[ 65] = 11'h259; x11_tab[ 66] = 11'h1F0; x11_tab[ 67] = 11'h6CE; x11_tab[ 68] = 11'h6D6; x11_tab[ 69] = 11'h55D; x11_tab[ 70] = 11'h223; x11_tab[ 71] = 11'h65E;
        x11_tab[ 72] = 11'h7CA; x11_tab[ 73] = 11'h330; x11_tab[ 74] = 11'h3F7; x11_tab[ 75] = 11'h348; x11_tab[ 76] = 11'h640; x11_tab[ 77] = 11'h26D; x11_tab[ 78] = 11'h340; x11_tab[ 79] = 11'h2DF;
        x11_tab[ 80] = 11'h752; x11_tab[ 81] = 11'h792; x11_tab[ 82] = 11'h5B0; x11_tab[ 83] = 11'h2FB; x11_tab[ 84] = 11'h398; x11_tab[ 85] = 11'h75C; x11_tab[ 86] = 11'h0A2; x11_tab[ 87] = 11'h524;
        x11_tab[ 88] = 11'h538; x11_tab[ 89] = 11'h74C; x11_tab[ 90] = 11'h1C5; x11_tab[ 91] = 11'h5A2; x11_tab[ 92] = 11'h522; x11_tab[ 93] = 11'h7C3; x11_tab[ 94] = 11'h6B3; x11_tab[ 95] = 11'h4F0;
        x11_tab[ 96] = 11'h5AC; x11_tab[ 97] = 11'h40B; x11_tab[ 98] = 11'h3E0; x11_tab[ 99] = 11'h1C8; x11_tab[100] = 11'h6FF; x11_tab[101] = 11'h291; x11_tab[102] = 11'h7C4; x11_tab[103] = 11'h47C;
        x11_tab[104] = 11'h6D9; x11_tab[105] = 11'h248; x11_tab[106] = 11'h623; x11_tab[107] = 11'h78D; x11_tab[108] = 11'h2CD; x11_tab[109] = 11'h356; x11_tab[110] = 11'h12A; x11_tab[111] = 11'h0BC;
        x11_tab[112] = 11'h582; x11_tab[113] = 11'h1D8; x11_tab[114] = 11'h1C6; x11_tab[115] = 11'h6EB; x11_tab[116] = 11'h7C2; x11_tab[117] = 11'h7F9; x11_tab[118] = 11'h650; x11_tab[119] = 11'h57D;
        x11_tab[120] = 11'h701; x11_tab[121] = 11'h7E5; x11_tab[122] = 11'h118; x11_tab[123] = 11'h1B4; x11_tab[124] = 11'h4AD; x11_tab[125] = 11'h2B8; x11_tab[126] = 11'h2BB; x11_tab[127] = 11'h765;
        x11_tab[128] = 11'h2D9; x11_tab[129] = 11'h46A; x11_tab[130] = 11'h020; x11_tab[131] = 11'h2DA; x11_tab[132] = 11'h5E4; x11_tab[133] = 11'h115; x11_tab[134] = 11'h53C; x11_tab[135] = 11'h2B4;
        x11_tab[136] = 11'h16D; x11_tab[137] = 11'h0F7; x11_tab[138] = 11'h633; x11_tab[139] = 11'h1A6; x11_tab[140] = 11'h0A0; x11_tab[141] = 11'h3E6; x11_tab[142] = 11'h29D; x11_tab[143] = 11'h77B;
        x11_tab[144] = 11'h558; x11_tab[145] = 11'h185; x11_tab[146] = 11'h7B9; x11_tab[147] = 11'h0B1; x11_tab[148] = 11'h36E; x11_tab[149] = 11'h4D3; x11_tab[150] = 11'h7E2; x11_tab[151] = 11'h5F9;
        x11_tab[152] = 11'h3D2; x11_tab[153] = 11'h21E; x11_tab[154] = 11'h0E1; x11_tab[155] = 11'h2AC; x11_tab[156] = 11'h0FC; x11_tab[157] = 11'h0FC; x11_tab[158] = 11'h66D; x11_tab[159] = 11'h7B5;
        x11_tab[160] = 11'h4AF; x11_tab[161] = 11'h627; x11_tab[162] = 11'h0F4; x11_tab[163] = 11'h621; x11_tab[164] = 11'h58F; x11_tab[165] = 11'h3D7; x11_tab[166] = 11'h1BC; x11_tab[167] = 11'h10A;
        x11_tab[168] = 11'h458; x11_tab[169] = 11'h259; x11_tab[170] = 11'h451; x11_tab[171] = 11'h770; x11_tab[172] = 11'h107; x11_tab[173] = 11'h134; x11_tab[174] = 11'h162; x11_tab[175] = 11'h32F;
        x11_tab[176] = 11'h5CF; x11_tab[177] = 11'h6C9; x11_tab[178] = 11'h670; x11_tab[179] = 11'h2D4; x11_tab[180] = 11'h0DA; x11_tab[181] = 11'h739; x11_tab[182] = 11'h30C; x11_tab[183] = 11'h62F;
        x11_tab[184] = 11'h4AF; x11_tab[185] = 11'h0E2; x11_tab[186] = 11'h3E3; x11_tab[187] = 11'h65C; x11_tab[188] = 11'h214; x11_tab[189] = 11'h066; x11_tab[190] = 11'h47D; x11_tab[191] = 11'h2F2;
        x11_tab[192] = 11'h729; x11_tab[193] = 11'h566; x11_tab[194] = 11'h450; x11_tab[195] = 11'h3F2; x11_tab[196] = 11'h35D; x11_tab[197] = 11'h593; x11_tab[198] = 11'h593; x11_tab[199] = 11'h532;
        x11_tab[200] = 11'h008; x11_tab[201] = 11'h270; x11_tab[202] = 11'h479; x11_tab[203] = 11'h358; x11_tab[204] = 11'h6F3; x11_tab[205] = 11'h7ED; x11_tab[206] = 11'h240; x11_tab[207] = 11'h587;
        x11_tab[208] = 11'h581; x11_tab[209] = 11'h00F; x11_tab[210] = 11'h750; x11_tab[211] = 11'h4D8; x11_tab[212] = 11'h1AB; x11_tab[213] = 11'h100; x11_tab[214] = 11'h47F; x11_tab[215] = 11'h34F;
        x11_tab[216] = 11'h497; x11_tab[217] = 11'h240; x11_tab[218] = 11'h769; x11_tab[219] = 11'h76F; x11_tab[220] = 11'h705; x11_tab[221] = 11'h375; x11_tab[222] = 11'h684; x11_tab[223] = 11'h273;
        x11_tab[224] = 11'h01F; x11_tab[225] = 11'h268; x11_tab[226] = 11'h2CC; x11_tab[227] = 11'h2D7; x11_tab[228] = 11'h5D4; x11_tab[229] = 11'h284; x11_tab[230] = 11'h40C; x11_tab[231] = 11'h5E8;
        x11_tab[232] = 11'h7C1; x11_tab[233] = 11'h281; x11_tab[234] = 11'h518; x11_tab[235] = 11'h4B0; x11_tab[236] = 11'h136; x11_tab[237] = 11'h73B; x11_tab[238] = 11'h3EA; x11_tab[239] = 11'h023;
        x11_tab[240] = 11'h1C1; x11_tab[241] = 11'h7DE; x11_tab[242] = 11'h106; x11_tab[243] = 11'h275; x11_tab[244] = 11'h1E1; x11_tab[245] = 11'h503; x11_tab[246] = 11'h30A; x11_tab[247] = 11'h271;
        x11_tab[248] = 11'h4F8; x11_tab[249] = 11'h52B; x11_tab[250] = 11'h266; x11_tab[251] = 11'h375; x11_tab[252] = 11'h024; x11_tab[253] = 11'h399; x11_tab[254] = 11'h672; x11_tab[255] = 11'h6F8;
    end

    //---------------- stage 0: index derivation ----------------
    // i1 = (i & 0xFF) ^ ((i>>15)&1) ^ (((i>>20)&1) << 8)
    // The XOR by a single bit only ever touches bit 0, and i2 is just the
    // low 8 bits of i1, so both indices come out of the same wires.
    wire [8:0] i1 = {idx[20], idx[7:1], idx[0] ^ idx[15]};
    wire [7:0] i2 = i1[7:0];
    wire [7:0] i3 = idx[15:8];
    wire [3:0] i4 = idx[19:16];

    reg [4:0]  rot_q;
    reg [4:0]  x5_q;
    reg [10:0] x11_q;
    reg [3:0]  i4_q;
    reg [31:0] din_q;
    reg        v_q;
    always_ff @(posedge clk) begin
        rot_q <= rot_tab[i1];
        x5_q  <= x5_tab[i2];
        x11_q <= x11_tab[i3];
        i4_q  <= i4;
        din_q <= din;
        v_q   <= in_valid;
    end

    //---------------- stage 1: rotate and key word ----------------
    // Verilog shifts wider than the operand give 0, so the r == 0 case
    // that C would leave undefined needs no special handling here.
    wire [5:0]  rsh = 6'd32 - {1'b0, rot_q};
    wire [31:0] rotated = (din_q << rot_q) | (din_q >> rsh);

    // gm(): nibble i of the result is 0xF when bit i of i4 is set.
    wire [15:0] gm = {{4{i4_q[3]}}, {4{i4_q[2]}}, {4{i4_q[1]}}, {4{i4_q[0]}}};
    wire [15:0] x1_low = {x5_q, 11'd0} ^ {5'd0, x11_q} ^ gm;

    reg [31:0] rot_q2;
    reg [15:0] x1_low_q;
    reg        v_q2;
    always_ff @(posedge clk) begin
        rot_q2   <= rotated;
        x1_low_q <= x1_low;
        v_q2     <= v_q;
    end

    //---------------- stage 2: permute, add, xor ----------------
    wire [31:0] v1 = {rot_q2[25], rot_q2[28], rot_q2[15], rot_q2[19], rot_q2[6], rot_q2[0], rot_q2[3], rot_q2[24], rot_q2[11], rot_q2[1], rot_q2[2], rot_q2[30], rot_q2[16], rot_q2[7], rot_q2[22], rot_q2[17], rot_q2[31], rot_q2[14], rot_q2[23], rot_q2[9], rot_q2[27], rot_q2[18], rot_q2[4], rot_q2[10], rot_q2[13], rot_q2[20], rot_q2[5], rot_q2[12], rot_q2[8], rot_q2[29], rot_q2[26], rot_q2[21]};
    wire [15:0] x1_hi = {x1_low_q[0], x1_low_q[8], x1_low_q[1], x1_low_q[9], x1_low_q[2], x1_low_q[10], x1_low_q[3], x1_low_q[11], x1_low_q[4], x1_low_q[12], x1_low_q[5], x1_low_q[13], x1_low_q[6], x1_low_q[14], x1_low_q[7], x1_low_q[15]};
    wire [31:0] x1 = {x1_hi, x1_low_q};
    wire [31:0] addend = x1 ^ PRE_XOR;

    // Partial carry sum: carry propagates from bit i to i+1 only where the
    // mask is set, and the carry out of bit 31 folds back as an XOR into
    // bit 0 of the result -- into the result, not the chain, so there is no
    // combinational loop. The mask is constant, so this synthesises as a
    // handful of independent adders, the widest of them 4 bits.
    wire [32:0] pc;
    wire [31:0] psum;
    assign pc[0] = 1'b0;
    genvar gi;
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : g_pcs
            wire [1:0] bsum = v1[gi] + addend[gi] + pc[gi];
            assign psum[gi] = bsum[0];
            if (((CARRY_MASK >> gi) & 32'd1) == 32'd1)
                assign pc[gi+1] = bsum[1];
            else
                assign pc[gi+1] = 1'b0;
        end
    endgenerate

    always_ff @(posedge clk) begin
        dout      <= (psum ^ {31'd0, pc[32]}) ^ POST_XOR;
        out_valid <= v_q2;
    end

endmodule
