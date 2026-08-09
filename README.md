# Arcade-Raiden2_MiSTer

A MiSTer FPGA core for **Raiden II** (Seibu Kaihatsu, 1993).

> **Status: runs on real hardware, 14/14 self-test checks pass. Not playable yet.**
> Verified on a DE10-Nano on 4 Aug 2026: PLL, ROM load, full 14 MB SDRAM
> readback through both ports, CPU fetch, CPU boot, vblank IRQ, both COP DMA
> channels, CRAM and tilemap fill, GFX ROM fetch, sprite latch and pixel output
> all confirmed on silicon.
>
> Still missing for playability: the **SEI252 sprite renderer**, the **SEI360
> mixer**, and **all sound** -- and note that sound is not optional, because
> coins are read through the Z80 (see RESEARCH.md 2.6), so the game cannot be
> started without it.
>
> It boots into an **on-screen self test** (see below) rather than a black
> screen. That page found three real defects on its first hardware run.

## What works

| Subsystem | State |
|---|---|
| NEC V30 CPU | Runs real program code; boots, clears RAM, reaches its main loop |
| Memory map + program banking | Complete, matches MAME's `raiden2_mem()` |
| vblank IRQ (vector 0x30) | Working — 68 frames observed in simulation |
| COP DMA (tilemap + palette) | Working and verified; modes 0x14 / 0x15 |
| SEI252 sprite RAM latch (0x68E) | Working — fires; source RAM is still all zeros (see below) |
| SEI0200 tilemap renderer | All four layers, **pixel-exact** against a reference model |
| CRTC scroll / enable / tile banks | `raiden2_video_regs`, driven by the CPU's register window |
| Video timing | 320x240 @ 55.4078 Hz, verified exact |
| Core self test | 14 checks on screen at boot; SDRAM BIST verified by fault injection |
| SDRAM + ROM loader | **Validated on hardware** — full 14 MB checksummed through ch1 and ch3 |
| clk_sys / clk_ram CDC | **Validated on hardware** — 96 MHz, pulse widening + SDC exceptions |

## What is missing

- **COP command engine — partially done, and the sprite list now populates.**
  Implemented and verified bit-exact against MAME (52/52, `make -C ../sim cop-run`):
  position/velocity `0205 0905 0904 2a05`, dword moves `5205 5a05 f205`,
  distance/sqrt `3b30 3bb0 39b0`, divide `42c2 4aa0`, angle step `6200`, and
  collision `a100 a900 b100 b900`.
  Still missing: **atan2** (`130e 2288 338e`) and **sin/cos** (`8100 8900`), both
  of which MAME computes in `double` and so need care to match exactly.

  > An earlier version of this file claimed the game "never builds a sprite
  > list". That was an artefact of only ever running the sim for 20M cycles.
  > At 150M cycles the game reaches attract mode and the buffer contains
  > **97 non-zero words, 23 entries with a tile code**. The list is real.

Still unported from MAME's DMA set, and the only modes `dma_unknown` now reports:
`0x09` / `0x0e` (word copy), `0x80–0x87` (palette fade) and `0x116`. The game has
not been seen to use any of them.

### What the self test found on its first hardware run

Three real defects, none of which simulation could have caught:

1. **COP DMA mode `0x118` (`dma_fill`) was missing.** 42 triggers, all with
   `dst = 0` so MAME's invalid-guard does not apply. Every one fills from
   somewhere in sprite RAM up to exactly `0x0D000` with zeros — it is the
   **sprite list terminator**, and the start offset states the list length
   (`0x0C040` = 8 entries, `0x0C0C0` = 24, `0x0C100` = 32). Now implemented.
2. **Our error detection was over-eager.** After the fill landed, the page still
   failed and reported mode `0x000` — `dma_mode` at its reset value, i.e. the
   game triggers `0x6FC` without selecting a channel. MAME's dispatch has no
   `case 0` and no `default`, so it does nothing, and so should we.
   `dma_unknown` now means "a mode with behaviour MAME implements and we have
   not ported", not "a mode number I do not recognise".
3. **A 512-deep register file appeared out of nowhere.** Reading `size_file`
   and `dst_file` for the fill materialised two 8192-flop arrays that Quartus
   had previously optimised away entirely (their values were never read). The
   design went 34% -> 43% and broke **hold** timing. Fixed by reading them
   synchronously so they infer as M10K.

Lesson worth keeping: (1) needed minutes of real runtime — 150M sim cycles is
only ~2.3 s of game time. (2) was only diagnosable because the page prints the
offending mode number; "COP MODES KNOWN: FAIL" alone would have sent us hunting
a bug in correct code. (3) was invisible to every testbench and only showed up
in the utilisation delta.
- **SEI252 sprite renderer** and the **SEI360 mixer** (including alpha blending).
- **All sound**: Z80, Seibu latch, YM2151, 2× OKI6295.
- **r2crypt sprite decryption in the loader** — currently only done offline by
  `tools/build_rom.py`. The MRA delivers sprites encrypted.

## Core self test

The core powers on into a pass/fail page instead of a black screen, because the
SDRAM controller, the ROM loader and both fetch handshakes have **no simulation
coverage at all** — the Verilator harness tops out at `raiden2_main` and answers
ROM requests combinationally. A fault in any of them looks identical from the
outside: nothing on screen.

Turn it off in the OSD (`Self test → Off`) to see the game's video. It is
observation-only; nothing in it can change how the core behaves.

Fourteen checks, in display order: PLL lock, ROM load, SDRAM verify, CPU fetch,
CPU boot, vblank IRQ, COP DMA tilemap, COP DMA palette, COP modes known, CRAM
filled, tilemap filled, GFX ROM fetch, sprite latch, pixels out.

Liveness checks start at `WAIT` and turn `FAIL` after 8 frames, so the page
settles into a real verdict rather than sitting on `WAIT`.

**SDRAM verify** is the substantial one. Every word is checksummed as the HPS
downloads it, then the whole image is read back through *both* read channels and
compared:

- **ch3**, the 16-bit read/write port the CPU fetches through;
- **ch1**, the 32-bit port the tile fetcher uses, whose half-word ordering is
  the item this README previously listed as never having been run against real
  SDRAM.

Checksums are kept per 64 KB block, so a failure reports the base address of the
first bad block and which channel saw it, rather than just "bad". A
non-contiguous download reports `0xFFFFFF` instead of an address, so a loader
problem is never mistaken for a memory fault. The sweep takes roughly a second,
during which the page shows `BUSY`; the core is held in reset meanwhile, since
the BIST owns both read channels.

The page renders in raster order and therefore bypasses `screen_rotate` —
without that the text would run up the side of the vertical cabinet monitor.

Both ROMs it needs are generated and checked in:

```sh
python3 tools/make_font.py           # rtl/raiden2_font8x8.sv    (from a stock PSF font)
python3 tools/make_selftest_page.py  # rtl/raiden2_selftest_page.sv
```

## Building

Quartus Prime **17.0** (Lite is fine). On this machine it is installed at
`/storage01/tools/intelFPGA_lite/17.0` and runs natively — no Docker needed,
since Quartus bundles its own Qt.

```sh
export QUARTUS_ROOTDIR=/storage01/tools/intelFPGA_lite/17.0/quartus
export PATH=$QUARTUS_ROOTDIR/bin:$PATH
quartus_sh --flow compile Raiden2
```

Output lands in `output_files/Raiden2.rbf`.

Two things that will bite you if you deviate:
- The DE10-Nano device is **`5CSEBA6U23I7`**. The `...I7N` spelling found in
  some references is a marketing suffix and Quartus rejects it.
- Quartus 17.0 does **not** support `case (...) inside`, even though Verilator
  does. Use a priority if/else chain.

## Deploying

```sh
scp output_files/Raiden2.rbf  root@mister:/media/fat/_Arcade/cores/
scp "releases/Raiden II.mra"  root@mister:/media/fat/_Arcade/
# and raiden2.zip in /media/fat/games/mame/
```

## Simulation

The Verilator harness in `../sim` is the primary development loop and is much
faster than hardware iteration.

```sh
make -C ../sim run           # CPU + COP DMA + CRTC regs; dumps vram/cram/sprite buffers
make -C ../sim video-run     # SEI0200 renderer, diffed against the reference model
make -C ../sim bist-run      # SDRAM BIST against a modelled controller, with fault injection
make -C ../sim selftest-run  # renders the self-test page to PNG for review
```

`../tools/render_frame.py` is a Python reference model of the tilemap path.
`../tools/compare_frame.py` diffs the RTL output against it pixel for pixel —
that check should stay at 100% after any change to `sei0200.sv`.

`make run` tops out at `raiden2_sim_top`, which is `raiden2_main` plus
`raiden2_video_regs`. The CRTC state in `video_state.txt` therefore comes from
the RTL that ships in the core rather than a C++ shadow of it, so the pixel-exact
comparison covers the register decode too.

**Know what the sim does not cover.** Everything in `Raiden2.sv` between the core
and the SDRAM chip — the controller, the loader, both fetch handshakes — is
absent from `make run`, which serves ROM combinationally with `rom_ready` tied
high. A green `make run` says nothing about any of it. That gap is why the
self-test page exists, and why `bist-run` models the controller protocol
explicitly instead of trusting the main harness.

## Clocking (read before changing the PLL)

`clk_sys` is **64 MHz** and is not negotiable: `/8` gives the 8 MHz pixel clock
and `/2` the 32 MHz tick the V30's two-phase CE halves to 16 MHz.

`clk_ram` is **96 MHz**. It was 128 MHz — picked as 2× clk_sys so the req/ready
handshake was implicitly synchronous — but that does not close timing:
`sdram.sv`'s state machine → command decode tops out near 118 MHz on this
device. It began at +0.210 ns and went to **-0.844 ns** once the design grew.

96 MHz closes at **+2.0 ns** on clk_ram, but 96/64 is a 3:2 ratio, so the
crossing is no longer implicitly safe. Two things make it correct, and
**removing either will produce a core that hangs on a fetch that already
completed**:

1. **Pulse widening, both directions** (`Raiden2.sv`, SDRAM section).
   `sdram.sv` asserts `ch*_ready` for one clk_ram cycle — 10.4 ns against a
   15.6 ns clk_sys period, so it can fall between two sampling edges and be
   lost. It is stretched to two clk_ram cycles in the clk_ram domain, then
   rising-edge-detected on the clk_sys side so a pulse spanning two edges is
   consumed once. Requests are widened to two clk_sys cycles for the same
   reason relative to the SDC exceptions. `sdram.sv` itself is unmodified.
2. **The multicycle exceptions in `Raiden2.sdc`.** The clocks realign only every
   31.25 ns and the tightest launch/capture pair is 5.2 ns — half a clk_ram
   period. Nothing on that crossing is a single-cycle transfer, so relaxing
   setup by one destination cycle describes the hardware rather than hiding a
   violation.

If clk_ram ever returns to an integer multiple of clk_sys, both mechanisms
become harmless no-ops rather than wrong.

## Known risks

- The vendored SDRAM controller's refresh timing was tuned for the 120 MHz
  clock it runs at in Arcade-IremM92_MiSTer; it now runs at 96.
- **The whole clk_sys↔clk_ram handshake is unsimulated.** The pulse widening
  and edge detection above are reasoned-correct but have never executed — the
  Verilator harness serves ROM combinationally and never touches this path.
  `CPU FETCH` and `SDRAM VERIFY` on the self-test page are the first real check.
- The half-word ordering of `ch1_dout` feeding the gfx byte-swap in
  `Raiden2.sv` checks out on paper: `sdram.sv` fills `dout[15:0]` from the
  first word of the burst (the one at `ch1_addr`) and `dout[31:16]` from the
  next, so the byte-swap does produce MAME's big-endian tile row. Still never
  run against real SDRAM — but the self test's ch1 sweep now checks exactly
  this, and `make -C ../sim bist-run` proves the check catches a swap.
- Video timing is modelled from MAME's `set_raw` and gives 55.4078 Hz /
  15.625 kHz, against PCB measurements of 55.4859 Hz / 15.5586 kHz — 0.14% and
  0.43% off respectively.

## Credits and licensing

GPLv3, as required by the framework and the vendored components.

Vendored from **Arcade-IremM92_MiSTer** (Martin Donlon / wickerwaka, GPL-2.0):
`sys/`, `rtl/sdram.sv`, `rtl/nec_core/` (the V30-class CPU), the RAM
primitives in `rtl/ram.sv`, the PLL, and this core's `emu` port list.

Behavioural reference is MAME's Seibu driver sources:
- `r2crypt.cpp` (BSD-3-Clause) — Andreas Naive, Olivier Galibert
- `sei25x_rise1x_spr.cpp`, `seibusound.cpp` (BSD-3-Clause)
- `raiden2.cpp`, `raiden2_v.cpp`, `seibucop.cpp`, `seibu_crtc.cpp`
  (LGPL-2.1+) — Olivier Galibert, Angelo Salese, David Haywood,
  Tomasz Slanina and others

LGPL-2.1+ permits relicensing to GPLv3 via its "or later" clause. Attribution
is required and retained here and in the derived file headers.

**No ROMs are included or should ever be committed.** The MRA references MAME
zips by CRC only.
