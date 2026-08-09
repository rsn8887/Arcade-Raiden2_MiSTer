//============================================================================
//  Debug trace over the HPS UART
//
//  sys_top wires the core's UART_TXD into cyclonev_hps_interface_peripheral_uart,
//  so bytes sent here arrive at the HPS UART and can be read on the board with
//
//      stty -F /dev/ttyS1 115200 raw -echo
//      cat /dev/ttyS1
//
//  (ttyS0 is the Linux console; ttyS1 is the fabric-connected one.)
//
//  This exists because debugging by reading hex off the self-test page costs a
//  20-minute rebuild per number. One line per frame is enough to watch the CPU
//  move, or fail to.
//
//  Format, one line per tick:
//      P=xxxxx L=xxxxx H=xxxxx S=xxxx
//  P  physical instruction address (PS*16 + PC) at the sample instant
//  L  lowest PC seen during the frame
//  H  highest -- L..H brackets everything executed, which is what separates
//     a stuck loop from a routine that is merely hot
//  S  status word: Z80/YM/COP/OKI flags and the video/IRQ state
//============================================================================

module raiden2_uart_log #(
    parameter int CLK_HZ = 64_000_000,
    parameter int BAUD   = 115200
) (
    input  logic        clk,
    input  logic        reset,

    input  logic [19:0] pc,
    input  logic [19:0] pc_lo,       // lowest PC seen since the last tick
    input  logic [19:0] pc_hi,       // highest
    input  logic [15:0] status,
    input  logic        tick,        // emit a line on this pulse

    output logic        txd
);

    localparam int DIV = CLK_HZ / BAUD;      // 555 at 64 MHz / 115200

    // ---- line buffer -----------------------------------------------------
    // Latched at tick so the values cannot slide mid-line.
    logic [19:0] pc_q, lo_q, hi_q;
    logic [15:0] st_q;

    localparam int LINE_LEN = 32;
    logic [4:0] idx;
    logic       sending;

    function automatic [7:0] hex(input [3:0] v);
        hex = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h41 + {4'd0, v} - 8'd10);
    endfunction

    // "P=xxxxx L=xxxxx H=xxxxx S=xxxx\r\n"
    //
    // L and H bracket every PC seen during the frame. Sampling a single PC
    // once per frame cannot tell a tight loop from a merely hot routine --
    // both land on the same address. The span does: a few bytes means stuck,
    // a wide range means the CPU is getting around.
    logic [7:0] ch;
    always_comb begin
        case (idx)
            5'd0:  ch = "P";
            5'd1:  ch = "=";
            5'd2:  ch = hex(pc_q[19:16]);
            5'd3:  ch = hex(pc_q[15:12]);
            5'd4:  ch = hex(pc_q[11:8]);
            5'd5:  ch = hex(pc_q[7:4]);
            5'd6:  ch = hex(pc_q[3:0]);
            5'd7:  ch = " ";
            5'd8:  ch = "L";
            5'd9:  ch = "=";
            5'd10: ch = hex(lo_q[19:16]);
            5'd11: ch = hex(lo_q[15:12]);
            5'd12: ch = hex(lo_q[11:8]);
            5'd13: ch = hex(lo_q[7:4]);
            5'd14: ch = hex(lo_q[3:0]);
            5'd15: ch = " ";
            5'd16: ch = "H";
            5'd17: ch = "=";
            5'd18: ch = hex(hi_q[19:16]);
            5'd19: ch = hex(hi_q[15:12]);
            5'd20: ch = hex(hi_q[11:8]);
            5'd21: ch = hex(hi_q[7:4]);
            5'd22: ch = hex(hi_q[3:0]);
            5'd23: ch = " ";
            5'd24: ch = "S";
            5'd25: ch = "=";
            5'd26: ch = hex(st_q[15:12]);
            5'd27: ch = hex(st_q[11:8]);
            5'd28: ch = hex(st_q[7:4]);
            5'd29: ch = hex(st_q[3:0]);
            5'd30: ch = 8'h0D;
            default: ch = 8'h0A;
        endcase
    end

    // ---- 8N1 transmitter -------------------------------------------------
    logic [15:0] baud_cnt;
    logic  [3:0] bit_idx;
    logic  [9:0] shifter;        // {stop, data[7:0], start}
    logic        busy;

    always_ff @(posedge clk) begin
        if (reset) begin
            txd      <= 1'b1;
            busy     <= 1'b0;
            sending  <= 1'b0;
            idx      <= 5'd0;
            baud_cnt <= 16'd0;
            bit_idx  <= 4'd0;
        end else begin
            if (tick && !sending) begin
                // Drop the request rather than queue it if a line is still
                // going out: a stalled line is better than a corrupted one.
                pc_q    <= pc;
                lo_q    <= pc_lo;
                hi_q    <= pc_hi;
                st_q    <= status;
                sending <= 1'b1;
                idx     <= 5'd0;
            end

            if (!busy) begin
                if (sending) begin
                    shifter  <= {1'b1, ch, 1'b0};
                    bit_idx  <= 4'd0;
                    baud_cnt <= DIV[15:0] - 16'd1;
                    busy     <= 1'b1;
                    txd      <= 1'b0;             // start bit
                end
            end else begin
                if (baud_cnt != 16'd0) begin
                    baud_cnt <= baud_cnt - 16'd1;
                end else begin
                    baud_cnt <= DIV[15:0] - 16'd1;
                    shifter  <= {1'b1, shifter[9:1]};
                    txd      <= shifter[1];
                    if (bit_idx == 4'd9) begin
                        busy <= 1'b0;
                        txd  <= 1'b1;
                        if (idx == LINE_LEN[4:0] - 5'd1) begin
                            sending <= 1'b0;
                        end else begin
                            idx <= idx + 5'd1;
                        end
                    end else begin
                        bit_idx <= bit_idx + 4'd1;
                    end
                end
            end
        end
    end

endmodule
