# Raiden II & Raiden DX for MiSTer

An FPGA recreation of the arcade board for **Raiden II** (Seibu Kaihatsu, 1993)
and **Raiden DX** (1994), for the MiSTer FPGA platform. One core runs both
games; the MRA tells it which board to be.

## Status

**Both games boot, play at full speed, and have sound.** All 22 built-in
self-test checks pass for both games on real hardware (a DE10-Nano).

Raiden II has had the most play-testing. Raiden DX became playable much more
recently, so treat it as the newer of the two — see
[Known problems](#known-problems) below.

## What the core covers

| Part of the arcade board | State |
|---|---|
| V30 main CPU | Working, incl. Raiden DX's 2 MB banked program ROM |
| Seibu COP (protection and maths chip) | Working — all 58 known commands match MAME, plus DX's own 0x7E05 |
| SEI252 sprite chip | Working, including sprite decryption for both ROM sets |
| SEI0200 tilemap chip (4 layers) | Working, incl. DX's swapped CRTC register layout |
| SEI360 mixer (layer priority, transparency) | Working |
| Sound — Z80, YM2151, two OKI6295 chips | Working |
| Video timing | 320x240 at 55.4078 Hz |
| SDRAM and ROM loading | Working — 14 MB (II) / 16.5 MB (DX) verified on hardware |

## Known problems

1. **Roughly one core load in four, the ROM data lands in SDRAM corrupted.**
   The built-in `SDRAM VERIFY` check catches it, and it is visible as a band
   of wrong graphics or wrong colours. It is decided at load time, not during
   play — **if the picture looks wrong, load the core again.** Not yet
   root-caused.
2. **Raiden DX is newly playable and lightly tested.** Both games pass the
   full self test, but DX has had hours of play-testing where Raiden II has
   had days. DX also pushes the sprite chip closer to its per-line time
   budget than any Raiden II scene measured so far.

An earlier version of this README reported some palette entries staying at
the wrong brightness (issue #74). That was disproved by measurement: the
palette was compared word-for-word against MAME across 1,016 attract frames —
2,080,768 comparisons including the flash-and-fade animations — with zero
divergence. The report came from a comparison-script bug, not the core.

Recently fixed and included in the current release:

- Raiden DX support in full: per-game memory map and decryption window, the
  DX-only COP command 0x7E05 (foreground tile banking), the swapped CRTC
  register layout, and the 8-byte scratch RAM at 0x4D0 whose absence left
  DX's canyon stage drawing placeholder tiles.
- See-through effects (engine flames, water, clouds) came out blue or purple,
  because the 50% colour blend discarded its carry and any channel pair over
  255 wrapped to near zero.
- Both graphics chips ran out of time on busy scanlines and dropped them.
  Dropped scanlines now measure zero on hardware.
- The picture sat off-centre on a CRT, with a black band down one side. The
  sync pulses were not centred in the blanking, and a monitor positions the
  image from the back porch. Only visible on a display fed the core's raw
  video; the scaler re-times everything, which is why it went unnoticed.
- Keyboard and analog stick support, which the core simply did not have.

## How to use it

You need three things on your MiSTer's SD card (four for both games):

1. `releases/Arcade-Raiden2_YYYYMMDD.rbf` → copy to `/media/fat/_Arcade/cores/`
   **and rename it to `Raiden2_YYYYMMDD.rbf`**, dropping the `Arcade-` prefix
2. `releases/Raiden II.mra` and/or `releases/Raiden DX.mra` → copy to
   `/media/fat/_Arcade/`
3. `raiden2.zip` and/or `raidendx.zip` (MAME ROM sets) → copy to
   `/media/fat/games/mame/`

Then pick **Raiden II** or **Raiden DX** from the Arcade menu. Both MRAs use
the same core file.

The rename is not optional. The `Arcade-` prefix is a *repository* naming
convention; on the SD card the core must match the `<rbf>Raiden2</rbf>` field
in the MRA. The MiSTer updater does this rename automatically, which is why no
installed core on a working system carries the prefix.

**No ROMs are included here, and none ever will be.** The `.mra` file only
lists which files it needs and checks them by CRC. You must supply your own.

### Which ROM sets — check yours before reporting graphics bugs

Raiden II exists in a dozen-plus regional revisions with different program
ROMs. The MRAs match the **parent sets** from MAME 0.264 by per-file CRC32
(listed inside each `.mra`). A different revision will load wrongly or not at
all, and the classic symptom is **wrong colours or garbled graphics** — if
you see that, or the built-in self test shows `SPRITE DECRYPT FAIL` /
`SDRAM VERIFY FAIL` on every load, verify your sets first.

The exact zips this core was verified against on hardware:

```
md5sum raiden2.zip  raidendx.zip
af1c4608fbe251313ff2552a780f472c  raiden2.zip
25532740c0f6f9942bac18e700a26d52  raidendx.zip
```

A zip with a different md5 is not automatically wrong (re-zipping the same
files changes it) — the per-file CRC32s in the MRA are the real test — but a
matching md5 means your set is exactly the one that was tested.

## Controls

Defaults follow the same layout as
[Arcade-Cave_MiSTer](https://github.com/MiSTer-devel/Arcade-Cave_MiSTer), so
shmups behave the same way across cores:

| Gamepad | Keyboard | Action |
|---|---|---|
| D-pad or left analog stick | Arrow keys | Move |
| A | Ctrl | Fire |
| B | Alt | Bomb |
| R | 1 | Start |
| L | 5 | Insert coin |
| Start | — | Pause |

The left analog stick works alongside the d-pad without any setup, and the
keyboard layout is the usual arcade one, so muscle memory from MAME carries
over. All gamepad buttons can be remapped in the MiSTer menu.

## Built-in self test

The core can run a self test that checks 22 things — the CPU, memory, video
chips, sound chips and so on — and shows the results on screen. It also sends
them over the debug serial port, which is how the core is tested without
anyone watching a monitor.

It is **off by default**; turn it on from the MiSTer menu under **Self test**,
which also offers two sprite-only display modes used for debugging graphics.

This exists because a black screen tells you nothing about *why* it is black.
The self test has found several real faults that simulation missed.

## Building it yourself

You need **Quartus Prime 17.0** (the free Lite edition works).

### Required packages

Quartus ships most of its own libraries — about 960 of them — so it needs very
little from the distribution, and the compile binaries are 64-bit, so no 32-bit
multilib is required.

```sh
# Debian / Ubuntu
sudo apt install libglib2.0-0 libnsl2 zlib1g libpcre2-8-0

# Fedora / RHEL
sudo dnf install glib2 libnsl zlib pcre2

# Arch
sudo pacman -S glib2 libnsl zlib pcre2
```

On a stock Ubuntu 24.04 install all of these are already present, including
`libnsl.so.1`, which is the one people usually expect to be missing.

**Use the command-line flow below rather than the Quartus GUI.** The GUI wants
`libpng12`, which distributions dropped years ago, along with old Qt libraries.
The command-line flow never loads either, which is why it still works on a
current system.

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
- Quartus 17.0 cannot **index a function call result** — `f(a,b)[5:4]` is a
  syntax error there and compiles fine under Verilator. Assign the call to a
  wire first, then slice the wire.
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

## How this core is tested

For each chip on the arcade board, a reference model was written from the MAME
source **first**, and the FPGA code is then compared against it — signal by
signal, or pixel by pixel.

Writing the model first matters: it is an independent implementation, so
agreement means something. Checking the FPGA code against a recording of its
own output would mean nothing.

| Chip | Compared against | Result |
|---|---|---|
| Seibu COP (protection/maths) | `tb_cop_cmd.cpp` vs MAME | all 58 commands match |
| Sprite decryption | `tools/r2crypt.py` | 200,032 test values, all exact |
| SEI360 mixer | `tools/mix_model.py` | 100,000 test values, all exact |
| SEI252 sprite chip | `tools/render_sprites.py` | 76,800 of 76,800 pixels match |
| SEI0200 tilemap chip | `tools/render_frame.py` | every pixel matches |
| Sound latch | `tb_seibu_latch.cpp` vs MAME | 36 of 36 cases match |

Every chip checked this way worked on real hardware the first time.

There are fourteen test benches, each runnable on its own:

```
spr-run   sprpaced-run  sprprot-run  cop-run    crypt-run  mix-run  latch-run
itoa-run  bist-run      selftest-run sdmain-run sound-run  vec-run  video-run
```

The sprite chip has **two** benches deliberately. `spr-run` draws every
scanline offline and compares it to the reference picture. `sprpaced-run`
starts a new line every 4,096 clocks whether the chip has finished the last one
or not, exactly as the real board does. The second exists because the first one
passed a change that doubled every sprite on real hardware: a test that treats
the chip more gently than the hardware does will keep passing forever.

The benches and reference models live in the wider development tree (`sim/` and
`tools/`), not in this repository.

### Timing budget

The sprite and tilemap chips each have 4,096 clocks to draw one scanline
(512 pixels × 8). Over that and the line is dropped, which looks like
flickering or missing graphics.

Where both chips stand on a DE10-Nano, measured per line:

| chip | worst line | budget | dropped scanlines |
|---|---|---|---|
| sprites (SEI252) | **3,973** | 4,096 | **0** |
| tilemaps (SEI0200) | **3,568** | 4,096 | **0** |

The sprite chip started at 8,262 clocks with 59 to 132 scanlines dropped per
frame. Three changes closed that: a duplicate memory fetch that made every
back-to-back read return the previous one's data; splitting the chip into a
scanner and a plotter so the next sprite is found while the current one is
still being drawn; and two scanner optimisations. The tilemap chip got the
same treatment for the column it was not prefetching.

A caution for anyone comparing against older notes: the on-chip counters
originally measured from one busy edge to the next, which spans several lines
whenever a line overruns, and they were never cleared per frame — so they
included start-up, when the ROM load saturates memory. One capture read 40,522
that way, which is not a fill time at all. They now restart every line. Any
figure recorded before that fix is an upper bound, not a per-line measurement.

### What the testing does **not** catch

The honest part, and worth reading before trusting a green result.

**Every hardware fault so far has been in the wiring *between* tested chips,
not inside them.** Each chip passed its own tests and was still wrong once
connected. The clearest example: the mixer passed 100,000 test values, and the
bug was in the arithmetic that blends two colours together — code sitting
outside the mixer, in the top level, where no test was looking.

**A test is only as good as what you feed it.** Four real cases:

- A sprite bench reported "76,800 of 76,800 pixels match" while its input list
  of sprites had been silently emptied. Blank matched blank perfectly.
- Two parts of the sprite chip hand work to each other. A fault in that
  handover could only occur when the timing was exactly back to back, and both
  benches left a comfortable gap, so neither could ever produce it. Real
  hardware leaves no gap.
- A bench modelled the sprite RAM as answering instantly when the real one
  answers a cycle later. It then **failed** the version that is correct for
  hardware and would have passed one that reads the wrong sprite.
- The tilemap bench ran with a ROM that answers instantly, which does not
  exist. At that setting the chip looked comfortably fast while the real one
  was near its limit.

All four were faults in the test harness, not the FPGA code. The benches now
refuse to run on empty input, model the real memory latency, and default to a
realistic ROM latency.

**`sdmain-run` does not include the sprite chip**, so it is not a test of it,
despite exercising the memory path that feeds it.

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
