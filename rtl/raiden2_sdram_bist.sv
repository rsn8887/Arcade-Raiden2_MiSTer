//============================================================================
//  Raiden II - SDRAM built-in self test
//
//  Checksums every word as the HPS downloads it, then reads the whole image
//  back through BOTH read paths and compares. This is the one block in the core
//  with no simulation coverage whatsoever -- the sim harness tops out at
//  raiden2_main and answers ROM requests combinationally, so the controller,
//  the loader and both fetch handshakes have never executed anywhere. A silent
//  fault here looks exactly like "the game does not boot".
//
//  Two sweeps, because the two ports differ in ways that can fail
//  independently:
//    ch3  16-bit read/write port, one word per request  -- the CPU's path
//    ch1  32-bit read-only port, two words per request  -- the tile path,
//         whose half-word ordering is called out as unvalidated in Raiden2.sv
//
//  sdram.sv returns the word at the request address in dout[15:0] and its
//  successor in dout[31:16]. The bursts are sequential and wrap inside an
//  aligned four-word group, so for any EVEN word address the first two returned
//  words are always addr and addr+1, in that order. Feeding them to the mixer
//  in that order makes the ch1 sweep produce the same checksum sequence as the
//  ch3 sweep and as the download -- which is precisely what validates the
//  half-word ordering.
//
//  Localisation is per 64 KB block: a checksum per block is kept in a 512-entry
//  table, so a failure reports the base address of the first bad block rather
//  than just "somewhere". Whole-image granularity would say almost nothing.
//
//  ASSUMPTION: the download is contiguous from address 0, which is what the MRA
//  produces (tools/build_rom.py packs the regions with no gaps). If it ever is
//  not, the sweep would read addresses that were never written and fail for the
//  wrong reason -- so the word count is checked against the address span and
//  reports BAD_GAP rather than a misleading address.
//============================================================================

module raiden2_sdram_bist (
    input  logic        clk,
    // Power-on reset ONLY. Deliberately not the OSD/user reset: the download
    // checksums cannot be rebuilt without another download, so clearing them on
    // a user reset would leave the SDRAM check permanently unable to run and it
    // would report FAIL on a perfectly good board. SDRAM contents survive a user
    // reset, so the previous verdict stays valid.
    input  logic        reset,

    // ROM download stream (ioctl, index 0)
    input  logic        dl_active,
    input  logic        dl_wr,
    input  logic [24:0] dl_addr,      // byte address, always even
    input  logic [15:0] dl_data,

    // ch3: 16-bit read/write port
    output logic [24:0] ch3_addr,
    output logic        ch3_req,
    input  logic [15:0] ch3_dout,
    input  logic        ch3_rdy,

    // ch1: 32-bit read-only port
    output logic [24:0] ch1_addr,
    output logic        ch1_req,
    input  logic [31:0] ch1_dout,
    input  logic        ch1_rdy,

    output logic        dl_complete,  // download finished and checksummed
    output logic        busy,         // hold the core in reset while high
    output logic        done,
    output logic        pass,
    output logic        bad_valid,
    output logic        bad_is_ch1,
    output logic [23:0] bad_addr
);

    // Sentinel reported when the download itself was not contiguous, so a
    // loader problem is never mistaken for a memory fault.
    localparam logic [23:0] BAD_GAP = 24'hFFFFFF;

    //------------------------------------------------------------------
    // Order-sensitive mixer. Not a CRC -- it only has to catch dropped,
    // duplicated, reordered and corrupted words, which is what the failure
    // modes here look like.
    //------------------------------------------------------------------
    function automatic [31:0] mix(input logic [31:0] s, input logic [15:0] d);
        mix = {s[30:0], s[31] ^ s[21]} ^ {d[7:0], d[15:8], d};
    endfunction

    //------------------------------------------------------------------
    // Per-64KB-block checksum table, written during download and read back
    // during the sweeps.
    //------------------------------------------------------------------
    logic  [8:0] blk_wr_addr, blk_rd_addr;
    logic [31:0] blk_wr_data, blk_rd_data;
    logic        blk_we;

    dualport_ram #(.widthad(9), .width(32)) blk_ram (
        .clock_a   (clk),
        .address_a (blk_wr_addr),
        .data_a    (blk_wr_data),
        .wren_a    (blk_we),
        .q_a       (),
        .clock_b   (clk),
        .address_b (blk_rd_addr),
        .data_b    (32'd0),
        .wren_b    (1'b0),
        .q_b       (blk_rd_data)
    );

    //------------------------------------------------------------------
    // Download side: accumulate a running checksum, flushing it into the table
    // whenever the block index changes and at end of download.
    //------------------------------------------------------------------
    logic [31:0] dl_sum;
    logic  [8:0] dl_blk;
    logic        dl_seen;
    logic [24:0] last_addr;
    logic [24:0] dl_words;
    logic        dl_done;
    logic        busy_run;      // set with dl_done; cleared by reset/restart

    assign dl_complete = dl_done;

    wire [8:0] this_blk = dl_addr[24:16];

    // A word arriving after a completed run means a new image is being loaded,
    // so the run re-arms. Keying that off the word rather than off a dl_active
    // edge matters: the first ioctl_wr can land in the same cycle dl_active
    // rises, and a separate clear branch would swallow word 0 -- which then
    // shows up as a bogus "non-contiguous download" on a perfectly good load.
    wire restart    = dl_wr & dl_done;
    wire first_word = dl_wr & (~dl_seen | dl_done);

    always_ff @(posedge clk) begin
        blk_we <= 1'b0;

        if (reset) begin
            dl_sum    <= 32'd0;
            dl_blk    <= 9'd0;
            dl_seen   <= 1'b0;
            last_addr <= 25'd0;
            dl_words  <= 25'd0;
            dl_done   <= 1'b0;
            busy_run  <= 1'b0;
        end else if (dl_wr) begin
            if (first_word) begin
                dl_sum   <= mix(32'd0, dl_data);
                dl_words <= 25'd1;
                dl_done  <= 1'b0;
                busy_run <= 1'b0;      // a new image re-arms the sweep
            end else if (this_blk != dl_blk) begin
                // Block boundary: commit the finished block, start the next.
                blk_wr_addr <= dl_blk;
                blk_wr_data <= dl_sum;
                blk_we      <= 1'b1;
                dl_sum      <= mix(32'd0, dl_data);
                dl_words    <= dl_words + 25'd1;
            end else begin
                dl_sum   <= mix(dl_sum, dl_data);
                dl_words <= dl_words + 25'd1;
            end
            dl_blk    <= this_blk;
            dl_seen   <= 1'b1;
            last_addr <= dl_addr;
        end else if (dl_seen && !dl_active && !dl_done) begin
            // Download finished: flush the final, possibly partial, block.
            blk_wr_addr <= dl_blk;
            blk_wr_data <= dl_sum;
            blk_we      <= 1'b1;
            dl_done     <= 1'b1;
            busy_run    <= 1'b1;   // same cycle as dl_done -- no reset glitch
        end
    end

    // Every word downloaded must account for exactly one address step of 2.
    wire contiguous = (dl_words == (last_addr >> 1) + 25'd1);

    //------------------------------------------------------------------
    // Sweep engine
    //------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE, S_START, S_REQ, S_WAIT, S_CHECK, S_NEXT, S_DONE
    } state_t;
    state_t state;

    logic        phase;          // 0 = ch3 sweep, 1 = ch1 sweep
    logic [24:0] addr;           // byte address of the next word to read
    logic [31:0] run_sum;
    logic  [8:0] run_blk;
    logic        got_hi;         // ch1 only: the second half is still to fold in

    // ch1 steps two words at a time; ch3 one.
    wire [24:0] addr_step = phase ? 25'd4 : 25'd2;
    wire [24:0] next_addr = addr + addr_step;

    // "this request is the last one", not "this address is the last word" --
    // the ch1 sweep covers two words per request, so testing the address alone
    // would run one request past the end of the image.
    wire last_word = next_addr > last_addr;

    // A block's checksum is compared when the sweep leaves it, or when the
    // sweep ends. cmp_mismatch has to be visible combinationally: a fault in
    // the FINAL block is discovered in the same cycle the verdict is latched,
    // so deriving pass from the registered bad_valid would read its old value
    // and report PASS on a bad board.
    wire cmp_now      = last_word || (next_addr[24:16] != run_blk);
    wire cmp_mismatch = cmp_now && (run_sum != blk_rd_data);

    assign ch3_addr = addr;
    assign ch1_addr = addr;

    // busy must rise in the SAME cycle dl_done does, not one cycle later when
    // the state machine has left S_IDLE. Otherwise the core reset -- which is
    // rom_load_busy | busy -- deasserts for exactly one clock between the end
    // of the download and the start of the sweep. In that clock the CPU fetch
    // logic can issue an sdr_cpu_req, and because the ch3 mux still selects the
    // CPU while busy is low, that stray request reaches the controller. Its
    // ready pulse then lands while the BIST is waiting on its own first read,
    // which corrupts block 0's checksum and reports a memory fault on a
    // perfectly good board.
    //
    // It must ALSO be cheap combinationally. busy selects the 25-bit ch3/ch1
    // address mux that feeds the SDRAM controller, and that mux sits on the
    // clk_sys -> clk_ram path to the SDRAM address pins, which is the design's
    // critical path. Deriving busy from the state encoding cost 0.76 ns and
    // pushed clk_ram to -0.394 ns: the two worst paths were literally
    // bist|dl_done -> sdram|SDRAM_A[11] and bist|state.S_IDLE -> the same pin.
    //
    // So it is one AND of two registers instead. busy_run is set in the same
    // cycle dl_done is (single driver, in the download block below), and done
    // is the sweep's own registered output, which preserves the timing that
    // the anti-glitch property needs.
    assign busy = busy_run & ~done;

    logic [15:0] hi_word;

    always_ff @(posedge clk) begin
        ch3_req <= 1'b0;
        ch1_req <= 1'b0;

        if (reset || restart) begin
            state      <= S_IDLE;
            done       <= 1'b0;
            pass       <= 1'b0;
            bad_valid  <= 1'b0;
            bad_is_ch1 <= 1'b0;
            bad_addr   <= 24'd0;
            phase      <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (dl_done) begin
                        if (!contiguous) begin
                            // Loader problem, not a memory problem. Say so.
                            done      <= 1'b1;
                            pass      <= 1'b0;
                            bad_valid <= 1'b1;
                            bad_addr  <= BAD_GAP;
                            state     <= S_DONE;
                        end else begin
                            phase <= 1'b0;
                            state <= S_START;
                        end
                    end
                end

                S_START: begin
                    addr    <= 25'd0;
                    run_sum <= 32'd0;
                    run_blk <= 9'd0;
                    got_hi  <= 1'b0;
                    state   <= S_REQ;
                end

                S_REQ: begin
                    if (phase) ch1_req <= 1'b1;
                    else       ch3_req <= 1'b1;
                    blk_rd_addr <= run_blk;
                    state       <= S_WAIT;
                end

                S_WAIT: begin
                    if (phase ? ch1_rdy : ch3_rdy) begin
                        if (phase) begin
                            run_sum <= mix(run_sum, ch1_dout[15:0]);
                            hi_word <= ch1_dout[31:16];
                            // The second word of the pair only counts if it is
                            // inside the downloaded range.
                            got_hi  <= (addr + 25'd2) <= last_addr;
                        end else begin
                            run_sum <= mix(run_sum, ch3_dout);
                            got_hi  <= 1'b0;
                        end
                        state <= S_CHECK;
                    end
                end

                S_CHECK: begin
                    if (got_hi) begin
                        run_sum <= mix(run_sum, hi_word);
                        got_hi  <= 1'b0;
                    end else begin
                        state <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    // Compare when the next address leaves this block, or when
                    // the sweep has consumed the last word.
                    if (cmp_now) begin
                        if (cmp_mismatch && !bad_valid) begin
                            bad_valid  <= 1'b1;
                            bad_is_ch1 <= phase;
                            // Block base as a byte address. The image tops out
                            // at 14 MB, so run_blk never exceeds 8 bits here.
                            bad_addr   <= {run_blk[7:0], 16'd0};
                        end
                        run_sum <= 32'd0;
                        run_blk <= next_addr[24:16];
                    end

                    if (last_word) begin
                        if (!phase) begin
                            phase <= 1'b1;      // now the 32-bit port
                            state <= S_START;
                        end else begin
                            done  <= 1'b1;
                            pass  <= ~(bad_valid | cmp_mismatch);
                            state <= S_DONE;
                        end
                    end else begin
                        addr  <= addr + addr_step;
                        state <= S_REQ;
                    end
                end

                default: ;   // S_DONE: latch and stay
            endcase
        end
    end

endmodule
