//============================================================================
//  Raiden II - OKI6295 sample line cache (SDRAM ch4)
//
//  Split out of raiden2_sound.sv so it can be simulated. raiden2_sound
//  instantiates T80, which is VHDL, so Verilator cannot elaborate it -- that
//  is the whole reason this block reached hardware with ZERO simulation
//  coverage and cost several 15-minute build/deploy cycles on HANDOFF #65.
//  The logic below is VERBATIM from raiden2_sound.sv; do not "improve" it here
//  without re-running `make sound-run`.
//
//  Each OKI gets a one-line 8-byte cache: ADPCM playback walks memory
//  sequentially, so one fetch covers eight consecutive reads and ch4 sees very
//  little traffic even with both channels streaming.
//============================================================================

module raiden2_oki_cache #(
    parameter [24:0] OKI1_BASE = 25'h0180000,
    parameter [24:0] OKI2_BASE = 25'h01C0000
) (
    input  logic        clk,            // clk_sys, 64 MHz
    input  logic        reset,

    // ---- jt6295 sample-ROM ports -------------------------------------
    input  logic [17:0] oki1_raddr,
    input  logic [17:0] oki2_raddr,
    output logic  [7:0] oki1_rdata,
    output logic  [7:0] oki2_rdata,
    output logic        oki1_ok,
    output logic        oki2_ok,

    // ---- SDRAM ch4 ---------------------------------------------------
    output logic [24:0] oki_addr,
    output logic        oki_req,
    input  logic [63:0] oki_dout,
    input  logic        oki_ack
);

    logic [63:0] line1, line2;
    logic [14:0] tag1, tag2;        // addr[17:3] of the cached line
    logic        val1, val2;

    wire hit1 = val1 && (tag1 == oki1_raddr[17:3]);
    wire hit2 = val2 && (tag2 == oki2_raddr[17:3]);
    assign oki1_ok = hit1;
    assign oki2_ok = hit2;
    assign oki1_rdata = line1[{3'd0, oki1_raddr[2:0]} * 8 +: 8];
    assign oki2_rdata = line2[{3'd0, oki2_raddr[2:0]} * 8 +: 8];

    logic serving;                  // 0 = oki1, 1 = oki2
    logic busy;

    // Timeout/retry. `busy` used to be cleared ONLY by oki_ack, so a single
    // unserved ch4 request latched it high forever: the block stopped asking
    // and all sample audio died for the rest of the session. Measured on
    // hardware 2026-08-07 -- 2 requests, 1 ready, then silence (HANDOFF #65).
    // No fetch path should hang permanently on one missed ack. ~64 us at
    // 64 MHz is far longer than any real SDRAM turnaround, so this only fires
    // on a genuine miss, and the retry makes the ch4 request counter climb
    // instead of freezing -- which is itself the diagnostic for whether the
    // misses continue.
    logic [11:0] oki_to;

    always_ff @(posedge clk) begin
        oki_req <= 1'b0;
        if (reset) begin
            val1 <= 1'b0; val2 <= 1'b0; busy <= 1'b0; serving <= 1'b0;
            oki_to <= 12'd0;
        end else if (!busy) begin
            // Round-robin so a continuously-streaming channel cannot starve
            // the other one.
            if (!hit1 && (serving == 1'b0 || hit2)) begin
                oki_addr <= OKI1_BASE + {4'd0, oki1_raddr[17:3], 3'd0};
                oki_req  <= 1'b1;
                serving  <= 1'b0;
                busy     <= 1'b1;
                oki_to   <= 12'd0;
            end else if (!hit2) begin
                oki_addr <= OKI2_BASE + {4'd0, oki2_raddr[17:3], 3'd0};
                oki_req  <= 1'b1;
                serving  <= 1'b1;
                busy     <= 1'b1;
                oki_to   <= 12'd0;
            end
        end else if (oki_ack) begin
            if (serving == 1'b0) begin
                line1 <= oki_dout; tag1 <= oki1_raddr[17:3]; val1 <= 1'b1;
                serving <= 1'b1;
            end else begin
                line2 <= oki_dout; tag2 <= oki2_raddr[17:3]; val2 <= 1'b1;
                serving <= 1'b0;
            end
            busy <= 1'b0;
        end else begin
            // Waiting on an ack that may never come.
            oki_to <= oki_to + 12'd1;
            if (&oki_to) busy <= 1'b0;      // give up and re-request
        end
    end

endmodule
