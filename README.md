# Raiden II for MiSTer

An FPGA recreation of the arcade board for **Raiden II** (Seibu Kaihatsu, 1993),
for the MiSTer FPGA platform.

## Status

**The game boots, plays, and has sound.** All 22 built-in self-test checks pass
on real hardware (a DE10-Nano).

It is **not finished**. Some colours are still wrong in places — see
[Known problems](#known-problems) below. Treat this as a work in progress
rather than a finished core.

## What the core covers

| Part of the arcade board | State |
|---|---|
| V30 main CPU | Working |
| Seibu COP (protection and maths chip) | Working — all 58 known commands match MAME |
| SEI252 sprite chip | Working, including sprite decryption |
| SEI0200 tilemap chip (4 layers) | Working |
| SEI360 mixer (layer priority, transparency) | Working |
| Sound — Z80, YM2151, two OKI6295 chips | Working |
| Video timing | 320x240 at 55.4078 Hz |
| SDRAM and ROM loading | Working, 14 MB verified on hardware |

## Known problems

These are the reasons the core is not finished yet:

1. **A few colours sit at the wrong brightness.** The real game runs a fade
   animation during attract mode that this core does not, so some palette
   entries stay too dark or too bright. This does not change which colour
   something is, only how light or dark. Issue #74.
2. **Only Raiden II is supported.** There is one MRA. Other sets in the same
   family, such as Raiden DX, are not covered.

Recently fixed and included in the current release: see-through effects
(engine flames, water, clouds) came out blue or purple because the colour
blend threw away its carry; and the sprite chip ran out of time on busy
scanlines and dropped them. Dropped scanlines now measure zero on hardware.

## How to use it

You need three things on your MiSTer's SD card:

1. `releases/Arcade-Raiden2_YYYYMMDD.rbf` → copy to `/media/fat/_Arcade/cores/`
2. `releases/Raiden II.mra` → copy to `/media/fat/_Arcade/`
3. `raiden2.zip` (a MAME ROM set) → copy to `/media/fat/games/mame/`

Then pick **Raiden II** from the Arcade menu.

**No ROMs are included here, and none ever will be.** The `.mra` file only
lists which files it needs and checks them by CRC. You must supply your own.

## Controls

| Button | Action |
|---|---|
| D-pad / stick | Move |
| A | Fire |
| B | Bomb |
| Start | Start game |
| Coin | Insert coin |

## Built-in self test

The core can run a self test that checks 22 things — the CPU, memory, video
chips, sound chips and so on — and shows the results on screen. It also sends
them over the debug serial port, which is how the core is tested without
anyone watching a monitor.

This exists because a black screen tells you nothing about *why* it is black.
The self test has found several real faults that simulation missed.

## Building it yourself

You need **Quartus Prime 17.0** (the free Lite edition works).

```sh
export QUARTUS_ROOTDIR=/path/to/intelFPGA_lite/17.0/quartus
export PATH=$QUARTUS_ROOTDIR/bin:$PATH
quartus_sh --flow compile Raiden2
```

The finished core appears at `output_files/Raiden2.rbf`.

Three things that will trip you up:

- The DE10-Nano chip is **`5CSEBA6U23I7`**. Some guides write `...I7N`; that is
  a marketing suffix and Quartus rejects it.
- Quartus 17.0 does not understand `case (...) inside`, even though Verilator
  does. Use an if/else chain instead.
- **Always check that timing passed before using a build.** Quartus prints
  "Full Compilation was successful" even when timing has failed. Search the
  log for `Timing requirements not met`.

## Clock speeds (read this before changing the PLL)

- **`clk_sys` is 64 MHz.** Divided by 8 it gives the 8 MHz pixel clock, and
  divided by 2 it gives the 32 MHz tick the V30 CPU needs.
- **`clk_ram` is 96 MHz.** It used to be 128 MHz, which looked tidy because it
  was exactly twice `clk_sys`, but the SDRAM controller cannot close timing
  that fast on this chip.

Because 96 and 64 are a 3:2 ratio, signals crossing between the two clocks are
**not** automatically safe. Two mechanisms make the crossing correct, and
removing either one produces a core that hangs waiting for data that already
arrived. Both are commented in `Raiden2.sv`.

## Testing

Development happens against reference models written from MAME, and there is a
test bench for each chip. See [docs/verification.md](docs/verification.md) for
what is tested, what the results are, and — importantly — what the tests are
known to miss.

The test benches and reference models live in the wider development tree
(`sim/` and `tools/`) rather than in this repository.

## Credits and licence

Licensed under the **GNU GPL v3** — see [LICENSE](LICENSE).

Framework and building blocks come from
**[Arcade-IremM92_MiSTer](https://github.com/MiSTer-devel/Arcade-IremM92_MiSTer)**
by Martin Donlon (wickerwaka), GPL-2.0: the `sys/` folder, the SDRAM
controller, the V30-class CPU core, the RAM primitives and the PLL.

Hardware behaviour was derived from the MAME source for the Seibu drivers:

- `r2crypt.cpp` (BSD-3-Clause) — Andreas Naive, Olivier Galibert
- `sei25x_rise1x_spr.cpp`, `seibusound.cpp` (BSD-3-Clause)
- `raiden2.cpp`, `raiden2_v.cpp`, `seibucop.cpp`, `seibu_crtc.cpp`
  (LGPL-2.1+) — Olivier Galibert, Angelo Salese, David Haywood,
  Tomasz Slanina and others

LGPL-2.1+ allows relicensing to GPLv3 through its "or later" clause.
Attribution is kept here and in the headers of the files concerned.

**Raiden II is a trademark of its respective owner. This project is not
affiliated with or endorsed by them.**
