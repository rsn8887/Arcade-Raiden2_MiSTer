//============================================================================
//  Raiden II - block RAM primitives
//
//  Two paths from one source so simulation and synthesis agree:
//    - Quartus: altsyncram, M10K, SINGLE_PORT, registered output.
//      Same parameters as Arcade-IremM92_MiSTer/rtl/dpramv.sv (Martin Donlon,
//      GPL-2.0), including ENABLE_RUNTIME_MOD so the In-System Memory Content
//      Editor can peek at RAM on real hardware.
//    - Verilator: behavioural model with the SAME two-cycle read latency
//      (address register + outdata register), so a design that works in sim
//      isn't silently relying on a faster memory than the hardware has.
//
//  read_during_write is DONT_CARE on the hardware side, so the behavioural
//  model doesn't attempt to define it either.
//============================================================================

`timescale 1ns / 1ps

module singleport_ram #(
    parameter width = 8,
    parameter widthad = 10,
    parameter name = "NONE"
) (
    input  wire                  clock,
    input  wire                  wren,
    input  wire [widthad-1:0]    address,
    input  wire [width-1:0]      data,
    output wire [width-1:0]      q
);

`ifdef VERILATOR

    reg [width-1:0] mem [0:(2**widthad)-1] /*verilator public*/;
    reg [width-1:0] q_stage1;
    reg [width-1:0] q_stage2;

    always @(posedge clock) begin
        if (wren) mem[address] <= data;
        q_stage1 <= mem[address];
        q_stage2 <= q_stage1;
    end

    assign q = q_stage2;

`else

    wire [width-1:0] q_int;
    assign q = q_int;

    altsyncram altsyncram_component (
        .address_a (address),
        .clock0 (clock),
        .data_a (data),
        .wren_a (wren),
        .q_a (q_int),
        .aclr0 (1'b0),
        .aclr1 (1'b0),
        .address_b (1'b1),
        .addressstall_a (1'b0),
        .addressstall_b (1'b0),
        .byteena_a (1'b1),
        .byteena_b (1'b1),
        .clock1 (1'b1),
        .clocken0 (1'b1),
        .clocken1 (1'b1),
        .clocken2 (1'b1),
        .clocken3 (1'b1),
        .data_b (1'b1),
        .eccstatus (),
        .q_b (),
        .rden_a (1'b1),
        .rden_b (1'b1),
        .wren_b (1'b0)
    );
    defparam
        altsyncram_component.clock_enable_input_a = "BYPASS",
        altsyncram_component.clock_enable_output_a = "BYPASS",
        altsyncram_component.intended_device_family = "Cyclone V",
        altsyncram_component.lpm_hint = {"ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=", name},
        altsyncram_component.lpm_type = "altsyncram",
        altsyncram_component.numwords_a = 2**widthad,
        altsyncram_component.operation_mode = "SINGLE_PORT",
        altsyncram_component.outdata_aclr_a = "NONE",
        altsyncram_component.outdata_reg_a = "CLOCK0",
        altsyncram_component.power_up_uninitialized = "FALSE",
        altsyncram_component.ram_block_type = "M10K",
        altsyncram_component.read_during_write_mode_port_a = "DONT_CARE",
        altsyncram_component.widthad_a = widthad,
        altsyncram_component.width_a = width,
        altsyncram_component.width_byteena_a = 1;

`endif

endmodule


//----------------------------------------------------------------------------
//  True dual-port RAM, one clock, one-cycle registered read, write-first.
//  Verbatim from Arcade-IremM92_MiSTer/rtl/dpramv.sv (Copyright (C) 2023
//  Martin Donlon, GPL-2.0). Already behavioural, so Quartus infers M10K from
//  it and Verilator simulates it directly -- no second path needed.
//
//  Used for the COP's destination buffers, where the CPU/COP write side and
//  the video read side are independent.
//----------------------------------------------------------------------------
module dualport_ram #(
    parameter width = 8,
    parameter widthad = 10
) (
    // Port A
    input   wire                  clock_a,
    input   wire                  wren_a,
    input   wire    [widthad-1:0] address_a,
    input   wire    [width-1:0]   data_a,
    output  reg     [width-1:0]   q_a,

    // Port B
    input   wire                  clock_b,
    input   wire                  wren_b,
    input   wire    [widthad-1:0] address_b,
    input   wire    [width-1:0]   data_b,
    output  reg     [width-1:0]   q_b
);

reg [width-1:0] ram[(2**widthad)-1:0] /*verilator public*/;

always @(posedge clock_a) begin
    if (wren_a) begin
        ram[address_a] <= data_a;
        q_a <= data_a;
    end else begin
        q_a <= ram[address_a];
    end
end

always @(posedge clock_b) begin
    if (wren_b) begin
        ram[address_b] <= data_b;
        q_b <= data_b;
    end else begin
        q_b <= ram[address_b];
    end
end

endmodule
