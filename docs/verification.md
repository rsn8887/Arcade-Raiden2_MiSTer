# Verification

How this core is tested, what that testing has caught, and — just as
importantly — what it has repeatedly failed to catch.

## Method: oracle-first

For each block, a reference model is written from the MAME sources *before* the
RTL, and the RTL is then diffed against it under Verilator. The model is an
independent implementation, not a recording of our own output, so agreement
means something.

| Block | Oracle | Result |
|---|---|---|
| `raiden2_cop_cmd` (Seibu COP) | `tb_cop_cmd.cpp` vs MAME | 58/58 commands |
| `raiden2_r2crypt` (sprite decrypt) | `tools/r2crypt.py` | 200,032 vectors exact |
| `raiden2_sei360` (mixer) | `tools/mix_model.py` | 100,000 vectors exact |
| `sei252` (sprite renderer) | `tools/render_sprites.py` | 76800/76800 pixels |
| `sei0200` (tilemaps) | `tools/render_frame.py` | pixel exact |
| `raiden2_seibu_latch` | `tb_seibu_latch.cpp` vs MAME | 36/36 |

Every oracle-checked block has been correct on hardware the first time it ran.

## Gates

Fourteen Verilator harnesses, each runnable standalone:

```
spr-run  sprpaced-run  sprprot-run  cop-run   crypt-run  mix-run  latch-run
itoa-run bist-run      selftest-run sdmain-run sound-run  vec-run  video-run
```

`sei252` is gated by two harnesses deliberately, because one is not enough:

- **`spr-run`** renders every scanline offline and diffs against
  `render_sprites.py` pixel for pixel.
- **`sprpaced-run`** drives `line_start` at the hardware cadence (every 4096
  clocks) into a possibly-busy engine, with request-time address latching, and
  classifies each line as clean / stale / corrupt.

The second exists because the first passed a change that doubled sprites on
real hardware. A bench that paces its stimulus more politely than the hardware
does will pass forever.

## On-hardware self test

The core streams a 22-check self test over the debug UART, decoded by
`tools/decode_selftest.py`. It covers PLL lock, ROM load, SDRAM verify, CPU
fetch/boot, VBLANK IRQ, COP DMA, CRAM/tilemap fill, GFX and sprite ROM fetch,
sprite decrypt, pixel output, the Z80, YM2151, and both OKI6295 channels.

Current status on a DE10-Nano: **22/22 PASS**.

This exists because on-screen checks could not report anything about the sound
path or about sprite fetching, and several conclusions drawn from watching the
screen turned out to be wrong.

## Known limitations of the testing

Stated plainly, because they are the honest part:

- **Every hardware bug so far has been in the untested wiring *between*
  oracle-checked blocks**, not inside them. Module-level correctness has not
  predicted integration correctness even once.
- A passing gate is only as good as its stimulus. Two separate incidents:
  a bench whose sprite-list input had been silently emptied still reported
  `76800/76800 EXACT MATCH`, and a two-sequencer handoff deadlock could not be
  reproduced by either bench because both idle far longer between lines than
  hardware does. Benches now assert their inputs are non-trivial, and the
  comparator refuses to return a verdict on a blank reference.
- `sdmain-run` exercises the CPU and SDRAM path but does **not** instantiate
  `sei252`, so it is not a gate for the sprite renderer.

## Not yet fully playable

Two known issues remain, and this core should not be considered finished until
they are closed:

1. The sprite renderer can exceed its per-line clock budget in dense scenes,
   dropping scanlines. Reduced substantially but not eliminated.
2. Inserting a coin can stop sprite ROM fetching, which is reproducible and
   under investigation.

## Reproducing

The harnesses and reference models live in the development tree alongside this
repository (`sim/`, `tools/`). Sprite-renderer inputs come from a long run of
the real game (`make run CYCLES=150000000`); shorter runs never reach attract
mode and produce an empty sprite list, which silently makes the comparison
vacuous.

**No ROMs are included anywhere in this repository.** The MRA references MAME
zips by CRC only.
