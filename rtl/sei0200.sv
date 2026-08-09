//============================================================================
//  Raiden II - SEI0200 tilemap generator
//
//  Renders the four tilemap layers into per-layer line buffers, one scanline
//  at a time, from the private buffer the COP DMA'd and the tile/char ROMs.
//
//  Ground truth: MAME src/mame/seibu/raiden2.cpp (gfx layouts) and
//  raiden2_v.cpp (layer order, palette bases, tile banking), LGPL-2.1+.
//
//  Layers, in the order SEI360 composites them:
//
//    idx  layer  map base  map size  tile  colour OR  palette base  ROM
//     0   BG      0x000     32x32     16     0x00        0x400      tiles
//     1   MID     0x800     32x32     16     0x20        0x400      tiles
//     2   FG      0x400     32x32     16     0x10        0x400      tiles
//     3   TXT     0xC00     64x32      8     0x00        0x700      chars
//
//  Map entry: bits 11:0 tile index (ORed with bank<<12), bits 15:12 colour.
//  Final CRAM index = palette base + colour*16 + pen, which packs the three
//  tilemap layers into 0x400-0x6FF and the text layer into 0x700-0x7FF.
//
//  GFX bit layout is the awkward part. A tile row is 32 bits holding 8 pixels
//  at 4bpp, but planes are interleaved and x runs in an odd order
//  (planeoffset {8,12,0,4}, xoffset {3,2,1,0,19,18,17,16}). Working that
//  through for a big-endian 32-bit word W gives a regular pattern:
//
//    j = i[1:0], b = i[2] ? 0 : 16
//    pen = { W[b+4+j], W[b+0+j], W[b+12+j], W[b+8+j] }
//
//  16x16 tiles are two such halves: left 8 pixels at byte offset row*4, right
//  8 at byte offset 64 + row*4, 128 bytes per tile. 8x8 chars are a single
//  half, 32 bytes per char.
//
//  One fetch engine walks all four layers sequentially rather than four
//  engines contending for the ROM port. Budget per line is about 2150 clocks
//  against 4096 available (512 pixel-times at 8 clk each), so it fits with
//  room to spare and needs no arbitration.
//
//  NOTE: line buffers are single-buffered here. A real raster needs them
//  double-buffered (fill line N+1 while displaying N); that comes with the
//  video timing generator.
//============================================================================

module sei0200 #(
    parameter int SCREEN_W = 320
) (
    input  logic        clk,
    input  logic        reset,

    // Line fill request
    input  logic [8:0]  line,        // scanline to prepare
    input  logic        start,
    output logic        busy,

    // Per-layer configuration
    input  logic [15:0] bg_scroll_x,  input logic [15:0] bg_scroll_y,
    input  logic [15:0] mid_scroll_x, input logic [15:0] mid_scroll_y,
    input  logic [15:0] fg_scroll_x,  input logic [15:0] fg_scroll_y,
    input  logic [2:0]  bg_bank,
    input  logic [2:0]  mid_bank,
    input  logic [2:0]  fg_bank,
    input  logic [2:0]  tx_bank,
    input  logic [4:0]  layer_enable, // ACTIVE LOW, bit0 BG .. bit3 TXT

    // Tilemap private buffer (filled by the COP DMA)
    output logic [12:0] map_addr,
    input  logic [15:0] map_data,

    // Tile / char ROM, 32-bit big-endian words at a byte address.
    // rom_req is held until rom_valid, so an SDRAM path with real latency can
    // stall the fetch engine without corrupting the line.
    output logic [22:0] rom_addr,
    output logic        rom_is_char,
    output logic        rom_req,
    input  logic [31:0] rom_data,
    input  logic        rom_valid,

    // Line buffer read ports, one per layer. Bit 11 set = opaque.
    //
    // Buffers are double-banked: a fill writes to fill_bank, which toggles on
    // every start. A live raster reads ~fill_bank (the line completed during
    // the previous scanline); an offline renderer that fills and then reads
    // the same line drives lb_rd_bank with fill_bank instead. The consumer
    // chooses, so both uses are explicit rather than implied.
    output logic        fill_bank,
    input  logic        lb_rd_bank,
    input  logic [8:0]  lb_rd_x,
    output logic [11:0] lb_bg,
    output logic [11:0] lb_mid,
    output logic [11:0] lb_fg,
    output logic [11:0] lb_txt
);

    localparam logic [9:0] W10 = SCREEN_W[9:0];

    // ------------------------------------------------------------------
    // Per-layer constants
    // ------------------------------------------------------------------
    logic [1:0] lyr;                  // 0 BG, 1 MID, 2 FG, 3 TXT
    wire        is_txt = (lyr == 2'd3);

    logic [12:0] map_base;
    logic [5:0]  colour_or;
    logic [10:0] pal_base;
    logic [2:0]  bank;
    logic [15:0] scr_x;
    logic [15:0] scr_y;

    always_comb begin
        case (lyr)
            2'd0: begin map_base = 13'h000; colour_or = 6'h00; pal_base = 11'h400;
                        bank = bg_bank;  scr_x = bg_scroll_x;  scr_y = bg_scroll_y;  end
            2'd1: begin map_base = 13'h800; colour_or = 6'h20; pal_base = 11'h400;
                        bank = mid_bank; scr_x = mid_scroll_x; scr_y = mid_scroll_y; end
            2'd2: begin map_base = 13'h400; colour_or = 6'h10; pal_base = 11'h400;
                        bank = fg_bank;  scr_x = fg_scroll_x;  scr_y = fg_scroll_y;  end
            default: begin map_base = 13'hC00; colour_or = 6'h00; pal_base = 11'h700;
                        bank = tx_bank;  scr_x = 16'd0;         scr_y = 16'd0;       end
        endcase
    end

    // ------------------------------------------------------------------
    // Line buffers
    // ------------------------------------------------------------------
    logic [8:0]  lb_wr_x;
    logic [11:0] lb_wr_d;
    logic [3:0]  lb_we;

    wire [9:0] lb_wa = {fill_bank,  lb_wr_x};
    wire [9:0] lb_ra = {lb_rd_bank, lb_rd_x};

    dualport_ram #(.widthad(10), .width(12)) lb0 (
        .clock_a(clk), .address_a(lb_wa), .data_a(lb_wr_d), .wren_a(lb_we[0]), .q_a(),
        .clock_b(clk), .address_b(lb_ra), .data_b(12'd0), .wren_b(1'b0), .q_b(lb_bg));
    dualport_ram #(.widthad(10), .width(12)) lb1 (
        .clock_a(clk), .address_a(lb_wa), .data_a(lb_wr_d), .wren_a(lb_we[1]), .q_a(),
        .clock_b(clk), .address_b(lb_ra), .data_b(12'd0), .wren_b(1'b0), .q_b(lb_mid));
    dualport_ram #(.widthad(10), .width(12)) lb2 (
        .clock_a(clk), .address_a(lb_wa), .data_a(lb_wr_d), .wren_a(lb_we[2]), .q_a(),
        .clock_b(clk), .address_b(lb_ra), .data_b(12'd0), .wren_b(1'b0), .q_b(lb_fg));
    dualport_ram #(.widthad(10), .width(12)) lb3 (
        .clock_a(clk), .address_a(lb_wa), .data_a(lb_wr_d), .wren_a(lb_we[3]), .q_a(),
        .clock_b(clk), .address_b(lb_ra), .data_b(12'd0), .wren_b(1'b0), .q_b(lb_txt));

    // ------------------------------------------------------------------
    // Geometry
    // ------------------------------------------------------------------
    wire [15:0] eff_y   = {7'd0, line} + scr_y;
    wire [5:0]  tile_y  = is_txt ? eff_y[8:3] : {1'b0, eff_y[8:4]};
    wire [3:0]  row_now = is_txt ? {1'b0, eff_y[2:0]} : eff_y[3:0];
    wire [3:0]  sub_x   = is_txt ? {1'b0, scr_x[2:0]} : scr_x[3:0];
    wire [6:0]  tx0     = is_txt ? scr_x[9:3] : {2'b0, scr_x[8:4]};

    logic [6:0] col;                  // tile column index being fetched
    logic [6:0] ncols;

    // While `map_pre` is set the map port addresses the NEXT column, so its
    // entry can be fetched under the current column's EMIT. Nothing else reads
    // map_data during EMIT, so borrowing the port there is free.
    logic       map_pre;
    wire [6:0] tile_x = tx0 + col + {6'd0, map_pre};

    always_comb begin
        if (is_txt) map_addr = map_base + {tile_y[4:0], 6'd0} + {7'd0, tile_x[5:0]};
        else        map_addr = map_base + {tile_y[4:0], 5'd0} + {8'd0, tile_x[4:0]};
    end

    // ------------------------------------------------------------------
    // Fetch / emit state machine
    // ------------------------------------------------------------------
    typedef enum logic [3:0] {
        IDLE, CLR, LAYER_INIT, MAP_RD, MAP_W1, MAP_W2,
        ROM_RD, ROM_WAIT, ROM_WAIT2, EMIT, NEXT_COL, NEXT_LAYER
    } state_t;
    state_t state;

    logic [14:0] code;
    logic [5:0]  colour;
    logic [3:0]  row_in_tile;
    logic [31:0] word;
    logic [3:0]  pix;                 // pixel within the current 8-pixel half
    logic        half;                // 0 = left 8, 1 = right 8 (16px tiles only)
    // ---- fetch pipeline (see the rom_req note below) ------------------
    logic [14:0] next_code;            // next column's tile, prefetched
    logic [5:0]  next_colour;
    logic        next_ok;
    logic        req_half;             // which half the IN-FLIGHT request is for
    logic        req_en;               // request held until its data arrives
    logic [31:0] word2;                // prefetched right half
    logic        word2_rdy;
    logic [9:0]  screen_x;            // wraps; out-of-range writes are dropped
    logic [8:0]  clr_x;

    // Pixel extraction, per the pattern derived from the gfx layout.
    wire [4:0] pb = pix[2] ? 5'd0 : 5'd16;
    wire [1:0] pj = pix[1:0];
    wire [3:0] pen = { word[pb + 5'd4  + {3'd0, pj}],
                       word[pb         + {3'd0, pj}],
                       word[pb + 5'd12 + {3'd0, pj}],
                       word[pb + 5'd8  + {3'd0, pj}] };

    wire [10:0] cram_index = pal_base + {1'b0, colour, 4'd0} + {7'd0, pen};

    assign busy        = (state != IDLE);
    // Held until the data arrives, then dropped for at least one clock: the
    // ch1 handshake in Raiden2.sv only accepts a new request when gfx_valid has
    // cleared, and gfx_valid clears on !gfx_req.
    assign rom_req     = req_en;
    assign rom_is_char = is_txt;

    // Spelled out as a mux rather than layer_enable[lyr]: bit 4 of
    // layer_enable is the sprite layer, which this module never draws, and
    // Quartus warns about the index width no matter how it is widened.
    logic layer_off;
    always_comb begin
        case (lyr)
            2'd0:    layer_off = layer_enable[0];   // BG
            2'd1:    layer_off = layer_enable[1];   // MID
            2'd2:    layer_off = layer_enable[2];   // FG
            default: layer_off = layer_enable[3];   // TXT
        endcase
    end

    always_comb begin
        // 32 bytes per 8x8 char, 128 bytes per 16x16 tile.
        if (is_txt) rom_addr = {6'd0, code[11:0], 5'd0} + {18'd0, row_in_tile[2:0], 2'd0};
        else        rom_addr = {1'b0, code, 7'd0} + {16'd0, req_half, 6'd0}
                             + {17'd0, row_in_tile, 2'd0};
    end

    always_ff @(posedge clk) begin
        lb_we <= 4'd0;

        if (reset) begin
            state     <= IDLE;
            fill_bank <= 1'b0;
            req_en    <= 1'b0;
            req_half  <= 1'b0;
            word2_rdy <= 1'b0;
            map_pre   <= 1'b0;
            next_ok   <= 1'b0;
        end else begin
            case (state)
                IDLE: if (start) begin
                    fill_bank <= ~fill_bank;
                    clr_x     <= 9'd0;
                    state     <= CLR;
                end

                // Blank every line buffer first, so disabled layers and gaps
                // read back transparent rather than stale.
                CLR: begin
                    lb_wr_x <= clr_x;
                    lb_wr_d <= 12'd0;             // bit 11 clear = transparent
                    lb_we   <= 4'b1111;
                    if (clr_x == W10[8:0] - 9'd1) begin
                        lyr   <= 2'd0;
                        state <= LAYER_INIT;
                    end else begin
                        clr_x <= clr_x + 9'd1;
                    end
                end

                LAYER_INIT: begin
                    if (layer_off) begin          // active low: 1 = off
                        state <= NEXT_LAYER;
                    end else begin
                        row_in_tile <= row_now;
                        col         <= 7'd0;
                        next_ok     <= 1'b0;
                        map_pre     <= 1'b0;
                        ncols       <= is_txt ? 7'd41 : 7'd21;
                        state       <= MAP_RD;
                    end
                end

                MAP_RD: state <= MAP_W1;
                MAP_W1: state <= MAP_W2;          // dualport_ram: one clock
                MAP_W2: begin
                    code     <= {bank, map_data[11:0]};
                    colour   <= {2'd0, map_data[15:12]} | colour_or;
                    half     <= 1'b0;
                    // Issue the left-half fetch now; `code` lands on this same
                    // edge, so rom_addr is correct when req_en goes high.
                    req_half  <= 1'b0;
                    req_en    <= 1'b1;
                    word2_rdy <= 1'b0;
                    // Screen position of this tile column's first pixel. This
                    // goes "negative" for the partially-scrolled first column
                    // and wraps to a large value, which the range test drops.
                    screen_x <= (is_txt ? {3'd0, col} << 3 : {3'd0, col} << 4)
                                - {6'd0, sub_x};
                    state    <= ROM_WAIT;
                end

                ROM_RD: state <= ROM_WAIT;      // retained; no longer entered

                ROM_WAIT: if (rom_valid) begin
                    word   <= rom_data;
                    pix    <= 4'd0;
                    req_en <= 1'b0;             // release so the next req is accepted
                    state  <= EMIT;
                end

                // Right half was prefetched during EMIT but had not landed in
                // time. Take whichever arrives -- the already-captured copy or
                // the live valid -- so a race between them cannot deadlock.
                ROM_WAIT2: begin
                    if (word2_rdy) begin
                        word      <= word2;
                        word2_rdy <= 1'b0;
                        pix       <= 4'd0;
                        state     <= EMIT;
                    end else if (rom_valid) begin
                        word   <= rom_data;
                        req_en <= 1'b0;
                        pix    <= 4'd0;
                        state  <= EMIT;
                    end
                end

                EMIT: begin
                    // The BACKGROUND layer is drawn OPAQUE -- pen 15 there is
                    // a real colour, not transparency. MAME draws it with
                    // TILEMAP_DRAW_OPAQUE, and the evidence is visual: BG tiles
                    // are 55% pen-15, so if it were transparent over half the
                    // foliage would be holes. MAME's output has none, while
                    // ours showed "large blocks of black in the centre of the
                    // trees". Overlay layers keep pen 15 as transparent (the FG
                    // tiles are 98% pen-15 -- clearly a mask). HANDOFF #71.
                    if (screen_x < W10 && (pen != 4'hF || lyr == 2'd0)) begin
                        lb_wr_x <= screen_x[8:0];
                        lb_wr_d <= {1'b1, cram_index};
                        lb_we   <= (4'b0001 << lyr);
                    end
                    screen_x <= screen_x + 10'd1;

                    // ---- prefetch the NEXT COLUMN's map entry -------------
                    // Costs nothing: the map is on-chip and its port is idle
                    // during EMIT. Removes MAP_RD/W1/W2 (3 clocks) from every
                    // column, ~100 columns per line = ~300 clocks -- which is
                    // about twice the measured 152-clock overrun.
                    if (pix == 4'd1) map_pre <= 1'b1;
                    if (pix == 4'd5 && map_pre) begin
                        next_code   <= {bank, map_data[11:0]};
                        next_colour <= {2'd0, map_data[15:12]} | colour_or;
                        next_ok     <= 1'b1;
                        map_pre     <= 1'b0;
                    end

                    // ---- prefetch the right half UNDER these 8 pixels ------
                    // Half the old per-column cost was a serialised SDRAM
                    // round trip (~12 clocks) followed by an 8-clock emit.
                    // Overlapping them is what buys the line-fill its margin
                    // back; see HANDOFF #70.
                    if (!is_txt && !half && !word2_rdy) begin
                        if (req_en) begin
                            if (rom_valid) begin
                                word2     <= rom_data;
                                word2_rdy <= 1'b1;
                                req_en    <= 1'b0;
                            end
                        end else begin
                            req_half <= 1'b1;
                            req_en   <= 1'b1;
                        end
                    end

                    if (pix == 4'd7) begin
                        if (!is_txt && !half) begin
                            half <= 1'b1;
                            // Do NOT consume word2 here: the prefetch block
                            // above may be capturing it on this very edge, and
                            // reading the stale word2_rdy would drop the data.
                            // ROM_WAIT2 settles it one clock later, and costs
                            // nothing when the prefetch already landed.
                            state <= ROM_WAIT2;
                        end else begin
                            state <= NEXT_COL;
                        end
                    end else begin
                        pix <= pix + 4'd1;
                    end
                end

                NEXT_COL: begin
                    if (col == ncols - 7'd1) begin
                        next_ok <= 1'b0;
                        state   <= NEXT_LAYER;
                    end else begin
                        col <= col + 7'd1;
                        if (next_ok) begin
                            // Map entry already in hand: skip MAP_RD/W1/W2 and
                            // go straight to requesting the tile row.
                            code      <= next_code;
                            colour    <= next_colour;
                            half      <= 1'b0;
                            screen_x  <= (is_txt ? {3'd0, (col + 7'd1)} << 3
                                                 : {3'd0, (col + 7'd1)} << 4)
                                         - {6'd0, sub_x};
                            req_half  <= 1'b0;
                            req_en    <= 1'b1;
                            word2_rdy <= 1'b0;
                            next_ok   <= 1'b0;
                            state     <= ROM_WAIT;
                        end else begin
                            state <= MAP_RD;
                        end
                    end
                end

                NEXT_LAYER: begin
                    if (lyr == 2'd3) state <= IDLE;
                    else begin
                        lyr   <= lyr + 2'd1;
                        state <= LAYER_INIT;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
