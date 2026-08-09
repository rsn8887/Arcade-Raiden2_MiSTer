//============================================================================
//  Raiden II - V30 instruction fetch path (direct-mapped instruction cache)
//
//  This module exists because the fetch path used to be written TWICE: once in
//  Raiden2.sv and once, independently, in sim/raiden2_sdram_top.sv so the
//  harness could measure it. Two copies of the thing under test is the trap
//  that has produced most of this project's hardware bugs -- the bench agrees
//  with itself and diverges from the board. One module, instantiated by both.
//
//  THE PROBLEM, measured rather than assumed
//  -----------------------------------------
//  sim/tb_sdmain with SD_TRAFFIC=0 -- no tilemap, sprite or sound traffic at
//  all -- showed the V30 stalled waiting on instruction fetch for 54.9% of
//  every cycle. Heavy contention took that only to 59.8%, so the cost was
//  never contention: it is the bare SDRAM round trip.
//
//  The CPU is clocked at 16 MHz like the real board, but stalling half the
//  time it was effectively running near 7 MHz, so game logic could not keep up
//  in busy scenes while the video stayed at a steady 55.4 fps. Seen from the
//  outside that is "it stutters in places".
//
//  WHAT DID NOT WORK, and why it is not worth retrying
//  --------------------------------------------------
//  A next-line prefetch -- speculatively pulling line+1 while the CPU chews
//  through the current one -- made things WORSE: 63.4% stalled, against 54.9%
//  without it. Demand fetches did drop 18%, so the guesses were often right,
//  but ch3 is single-outstanding like every other SDRAM channel, so a
//  speculative fetch BLOCKS the demand fetch queued behind it. A wrong guess
//  costs a full round trip twice over. Do not reintroduce it without first
//  giving ch3 a second outstanding request, which sdram.sv cannot do.
//
//  WHAT DOES WORK
//  --------------
//  The original cache held exactly ONE line of 8 bytes, so any loop longer
//  than 8 bytes thrashed it completely -- and every loop in the game is longer
//  than that. Making it a direct-mapped cache of NLINES lines keeps whole
//  loops resident, which is where the hit rate actually comes from.
//============================================================================

module raiden2_cpu_fetch (
    input  logic        clk,
    input  logic        reset,

    input  logic [24:0] base,          // SDR_MAINCPU; runtime, DX relocates
    input  logic        line_cache_en, // harness A/B; tie high in the core

    // V30 side
    input  logic [20:0] cpu_addr,      // 21 bits: Raiden DX banks past 1 MB
    input  logic        cpu_req,
    output logic [15:0] cpu_data,
    output logic        cpu_ready,

    // SDRAM ch3
    output logic [24:0] sdr_addr,
    output logic        sdr_req,
    input  logic [63:0] sdr_dout,
    input  logic        sdr_ack,

    // One pulse per program word that actually came back from SDRAM
    output logic        fetch_done,
    output logic        fetch_pending
);

    // NLINES lines of 4 words (8 bytes). 64 lines = 512 bytes of code held.
    localparam int IDXW = 6;
    localparam int NLINES = 1 << IDXW;

    logic [15:0] line     [0:NLINES*4-1];
    logic [17:0] line_tag [0:NLINES-1];
    logic        line_vld [0:NLINES-1];

    logic [15:0] data_r;
    logic [20:0] fetch_addr;

    wire [IDXW-1:0] cpu_idx   = cpu_addr[IDXW+2:3];
    wire [IDXW-1:0] fetch_idx = fetch_addr[IDXW+2:3];

    wire line_hit = line_cache_en & line_vld[cpu_idx]
                  & (cpu_addr[20:3] == line_tag[cpu_idx]);
    // The word still in flight, so a repeat request for it does not restart.
    wire word_hit = (cpu_addr[20:1] == fetch_addr[20:1]);

    wire fetch_start = cpu_req && !(line_hit || word_hit);

    assign cpu_ready  = ~fetch_pending & ~fetch_start;
    assign cpu_data   = line_hit ? line[{cpu_idx, cpu_addr[2:1]}] : data_r;
    assign fetch_done = fetch_pending & sdr_ack;

    integer i;
    always_ff @(posedge clk) begin
        sdr_req <= 1'b0;                // one-clock pulse, never a toggle

        if (reset) begin
            fetch_pending <= 1'b0;
            fetch_addr    <= 21'h1FFFFF;
            for (i = 0; i < NLINES; i = i + 1) line_vld[i] <= 1'b0;
        end else if (!fetch_pending) begin
            if (fetch_start) begin
                fetch_addr    <= cpu_addr;
                sdr_addr      <= base + {4'd0, cpu_addr};
                sdr_req       <= 1'b1;
                fetch_pending <= 1'b1;
            end
        end else if (sdr_ack) begin
            data_r        <= sdr_dout[15:0];
            fetch_pending <= 1'b0;

            // Scatter the burst into the line at its true group offsets.
            line[{fetch_idx,  fetch_addr[2:1]              }] <= sdr_dout[15:0];
            line[{fetch_idx, (fetch_addr[2:1] + 2'd1) & 2'd3}] <= sdr_dout[31:16];
            line[{fetch_idx, (fetch_addr[2:1] + 2'd2) & 2'd3}] <= sdr_dout[47:32];
            line[{fetch_idx, (fetch_addr[2:1] + 2'd3) & 2'd3}] <= sdr_dout[63:48];
            line_tag[fetch_idx] <= fetch_addr[20:3];
            line_vld[fetch_idx] <= 1'b1;
        end
    end

endmodule
