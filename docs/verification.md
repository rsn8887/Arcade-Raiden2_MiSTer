# How this core is tested

Short version: for each chip on the arcade board, a reference model was written
from the MAME source **first**, and the FPGA code is then compared against it,
signal by signal or pixel by pixel.

The point of writing the model first is that it is an independent
implementation. If the two agree, that means something. If the FPGA code were
checked against a recording of its own output, agreement would mean nothing.

## Results

| Chip | Compared against | Result |
|---|---|---|
| Seibu COP (protection/maths) | `tb_cop_cmd.cpp` vs MAME | all 58 commands match |
| Sprite decryption | `tools/r2crypt.py` | 200,032 test values, all exact |
| SEI360 mixer | `tools/mix_model.py` | 100,000 test values, all exact |
| SEI252 sprite chip | `tools/render_sprites.py` | 76,800 of 76,800 pixels match |
| SEI0200 tilemap chip | `tools/render_frame.py` | every pixel matches |
| Sound latch | `tb_seibu_latch.cpp` vs MAME | 36 of 36 cases match |

Every chip checked this way worked correctly on real hardware the first time.

## The test benches

There are fourteen, each one runnable on its own:

```
spr-run   sprpaced-run  sprprot-run  cop-run    crypt-run  mix-run  latch-run
itoa-run  bist-run      selftest-run sdmain-run sound-run  vec-run  video-run
```

The sprite chip has **two** benches on purpose:

- **`spr-run`** draws every scanline offline and compares it to the reference
  picture, pixel for pixel.
- **`sprpaced-run`** starts a new line every 4,096 clocks whether the chip has
  finished the last one or not, exactly as the real board does.

The second one exists because the first one passed a change that doubled every
sprite on real hardware. A test that treats the chip more gently than the
hardware does will keep passing forever.

## The self test on real hardware

The core runs 22 checks at start-up — clocks, memory, CPU, video chips, sound
chips — and sends the results over a serial port. On a DE10-Nano it currently
reads **22 out of 22**.

This exists because a picture on a monitor cannot tell you whether the sound
chip is fetching samples, and several conclusions drawn from simply watching
the screen turned out to be wrong.

## What the testing does **not** catch

This is the honest part, and it is worth reading before trusting a green result.

**Every hardware fault so far has been in the wiring *between* tested chips,
not inside them.** Each chip passed its own tests and was still wrong once
connected. The most recent example: the mixer passed 100,000 test values, and
the bug was in the arithmetic that blends two colours together — code that sits
outside the mixer, in the top level, where no test was looking.

**A test is only as good as what you feed it.** Two real cases:

- A sprite bench reported "76,800 of 76,800 pixels match" while its input list
  of sprites had been silently emptied. Blank matched blank perfectly. The
  benches now refuse to run on empty input.
- Two parts of the sprite chip hand work to each other. A fault in that handover
  could only happen when the timing was exactly back to back — and both benches
  left a comfortable gap, so neither could ever produce it. Real hardware leaves
  no gap.

**`sdmain-run` does not include the sprite chip**, so it is not a test of it,
despite exercising the memory path that feeds it.

## Not finished yet

The remaining known faults are listed in the [README](../README.md). This core
should not be considered complete until they are fixed.

## Measured on hardware

The sprite chip has a fixed budget of 4,096 clocks per scanline. Anything over
that and the line is dropped, which shows as flickering or missing sprites.
Progress over one day of work, read off the core's own counters on a DE10-Nano:

| | worst line | dropped scanlines |
|---|---|---|
| start of day | 8,262 | 59 to 132 |
| after the fetch fix | 6,793 | 69 on a boss |
| after splitting the sprite engine in two | 4,678 | 4 |
| after the scanner optimisations | **4,228** | **0** |

## Reproducing the tests

The benches and reference models live in the wider development tree (`sim/` and
`tools/`), not in this repository.

One thing to know: the sprite benches need a real list of sprites, produced by
running the game in simulation for a long time (`make run CYCLES=150000000`).
Shorter runs never reach the attract sequence and produce an empty list — which
silently makes the comparison meaningless, as described above.

**No ROMs are included anywhere in this repository.** The `.mra` file refers to
MAME ROM sets by CRC only.
