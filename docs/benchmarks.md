# UPS gate: modular-balancer against Better Belt Balancer and Belt Balancer 3

Plan 3 Task 1 (2026-10-25). Factorio 2.1.23, vanilla preset, express tier everywhere.

## Verdict

**Fail at 2:3, 3:5, 8:3, 17:2, 33:5 and 64:64**, with all outputs free and with one output
throttled. It passes only at 9:1.

The gate has two conditions:
- **Zero per-tick script time in the steady state: met.** modular-balancer has no script time in
  any save.
- **Total update time no worse than Better Belt Balancer's (BBB): not met.** It is 1.26x to 2.48x
  BBB's, far outside the noise.

Per the stop rule, work stopped here, and the design was not changed. Not measured: the Belt
Balancer 3 saves, `load_time_with_200_balancers` and the rebuild hitch (see "Not measured").

| ratio (copies) | all outputs free: mb / BBB | one output throttled: mb / BBB | plain network / BBB (free, throttled) |
| --- | --- | --- | --- |
| 2:3 (50) | 1.40x | 1.39x | 1.01x, 1.06x |
| 3:5 (50) | 1.40x | 1.39x | 1.21x, 1.15x |
| 8:3 (50) | 1.30x | 1.36x | 1.11x, 1.11x |
| 9:1 (50) | 0.97x (pass) | 0.96x (pass) | - |
| 17:2 (50) | 1.36x | 1.26x | - |
| 33:5 (50) | 1.71x | 1.74x | - |
| 64:64 (4) | 2.33x | 2.48x | - |
| 96:96 (4) | BBB: not supported | BBB: not supported | - |
| 128:128 (4) | BBB: not supported | BBB: not supported | - |

"Plain network" is this mod's generator with recirculation off (`network.build(n, m, { recirc =
false })`). It is the vanilla splitter balancer reference. Even without recirculation, it costs up
to 1.21x BBB's time (at 3:5).

### Why

The gap is engine transport-line time in the hidden networks, not script time.
`transportLinesUpdate` is 2x BBB's at 8:3 (0.187 against 0.092 ms) and 4.4x at 64:64 (0.770
against 0.175 ms). The networks are larger:

| network (per copy) | splitters | lane splitters | linked belts | belts |
| --- | --- | --- | --- | --- |
| mb 8:3 (recirculating) | 47 | 0 | 175 | 0 |
| mb 8:3 plain | 25 | 0 | 93 | 0 |
| BBB 8:3 | 12 | 8 | 27 | 16 |
| mb 64:64 (recirculating) | 961 | 0 | 3 714 | 0 |
| BBB 64:64 | 192 | 64 | 448 | 320 |

Why the networks differ in size:
- BBB's 64:64 has 192 = 6 x 32 splitters: one butterfly.
- This mod's plain 64:64 core is two butterflies, which makes it throughput-unlimited (spec Goal 2).
- The recirculating network adds the redistribution stage (spec Update 3).

So BBB is cheaper but gives weaker guarantees. The scout runs measured this (items per output over
1 200 ticks):
- 3:5 with output 1 throttled to 15/s:
  - BBB: `300, 781, 540, 539, 540`. The throttled output's share goes to one sibling.
  - modular-balancer: `300, 600, 600, 600, 599` (equal).
  - Belt Balancer 3: `300, 600, 600, 600, 600` (equal).
- BBB refuses balancers with more than 64 ports. For 96:96 and 128:128 its log says "would need 128
  ports ... over the limit of 64; refused".

Network size does not grow monotonically with the ratio (Plan 2 final review Minor 10): 4 x 96:96
costs 4.40 ms/tick, against 2.62 ms for 4 x 128:128.

## Method

### Saves

`bench/builders.lua` builds every save on a fresh map (seed 1) of an fdev server. It is part of the
remote interface `mb-test`, loads only with the dev gate `mb-dev`, and `bench/` is export-ignored.

**Layout.** Each save has `copies` balancers of one kind:
- Each balancer is a 2 x K block of parts, where K = max(N, M). Inputs enter the left column and
  outputs leave the right column. BBB allows one belt per part on 2.1, so every kind uses this same
  2 x K footprint.
- Each input: an infinity chest of iron plates, a 1x1 express loader (`mb-test-loader-express`) and
  two express belts.
- Each output: two express belts, a 1x1 express loader and an infinity chest that deletes
  everything. With "one throttled", the second belt of output 1 is a basic belt (15/s).
- Every visible entity is created with `raise_built`, as if a player built it.

**Map cleanup.** All enemies on nauvis are removed, with peaceful mode on and no expansion or
pollution. A first try had two problems, both fixed in the builder:
- worms near the build area destroyed parts;
- a chunk generated after the build wiped entities. The builder now checks that every chunk is
  generated before it builds.

**Kinds:**
- `mb`: blocks `mb-balancer-express` with the recirculating network (the default).
- `bbb`: `bbb-balancer-part` (better-belt-balancer 0.3.6).
- `bb3`: `balancer-part` (belt-balancer-3-unofficial-2-1 1.0.4).
- `plain`: no parts. `network.build(n, m, { recirc = false })` is placed by `builder.place` and
  joined by hidden linked belts.
  - This is the brief's "vanilla splitter balancer". It is built with the Plan 1 generator's
    non-recirculating mode, not from community blueprints.
  - It has the same hidden loader and buffer chest per network as `mb`, and no visible belts
  between splitters.

**Instances.** Each mod runs in its own instance:
- `mb` and `plain`: modular-balancer and factorio-test.
- `bbb`: modular-balancer, factorio-test and better-belt-balancer. modular-balancer is loaded
  because the builder lives in it. It does nothing there (0 script time).
- BBB and Belt Balancer 3 cannot share an instance: BBB adopts Belt Balancer 3's `balancer-part` as
  a legacy part.

**Steady state.** Each save ran 5 400 ticks at game speed 30, then 2 400 ticks at speed 1 while
ticklens sampled it, and was then saved.

### Measurements

- **Total update time:** fdev `benchmark_compare` with 5 rounds of 1 000 ticks per run (the first
  100 dropped). It is an A/A comparison: two instances with the same mods alternate on the same
  save, which gives 10 runs per save. The tables show the median of the 10 run medians, with the
  min and max.
- **Noise:** derived from the rounds. For "X against BBB":
  - `noise = 2 * sqrt(sd_X^2 / 10 + sd_BBB^2 / 10)`, where sd is the standard deviation of a save's
    10 run medians. This is about a 95 % bound on the difference.
  - It is 0.005-0.045 ms, or 2.3-10.6 % of BBB's time.
  - The A/A deltas between the two instances on one save were -8.6 % to +7.8 %.
  - Every failing difference is at least 3.6x its noise (2:3 throttled is the closest).
- **Script time per mod:** `ticklens report --pid <server pid> --duration 30 --json`
  (`bench/ticklens.sh`, ticklens 0.1.0).
  - The table shows the engine's own per-mod timer (`engine.mods`, exact) and ticklens' sampled
    self time.
  - modular-balancer is absent from the engine timers in every save: 0 ms/tick. BBB is also 0.
  - The only per-tick script is factorio-test's `udp-rerun` `on_nth_tick(1)`, up to
    0.016 ms/tick, in every instance.
  - The 6.0 ms sampled for mb 2:3 free is the `bench_counts` remote call made during that sample,
    not steady-state work.
- **Entity counts:** from `bench_counts`. Visible = nauvis; hidden = the hidden surfaces.
- **Raw numbers:** one file per save in `docs/benchmarks/raw/<kind>-<N>x<M>-<free|thr>.json`, with
  the run medians, the ticklens summary and the entity counts. `python -I bench/tables.py` prints
  the tables below.

## Tables

ms/tick values are medians over 10 runs. "vs BBB" gives the ratio to BBB with the same outputs and
the difference in ms. The gate passes when the difference is not above the noise.

### 50 x 2:3

| balancer | outputs | wholeUpdate ms/tick median [min..max] | transportLines | entityUpdate | script ms/tick (ticklens, engine timer) | visible / hidden entities | vs BBB | noise | gate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| modular-balancer | all free | 0.343 [0.306..0.424] | 0.121 | 0.081 | 0.0000 (6.0 ms sampled) | 1300 / 8000 | 1.40x (+0.098) | 0.026 | **fail** |
| Better Belt Balancer | all free | 0.244 [0.231..0.296] | 0.063 | 0.065 | 0.0000 (0.0 ms sampled) | 1550 / 1100 |  |  |  |
| plain splitter network (vanilla reference) | all free | 0.248 [0.238..0.266] | 0.064 | 0.070 | 0.0000 (0.0 ms sampled) | 1000 / 2200 | 1.01x (+0.004) | 0.013 | (reference) |
| modular-balancer | one throttled | 0.340 [0.317..0.438] | 0.130 | 0.080 | 0.0000 (0.0 ms sampled) | 1300 / 8000 | 1.39x (+0.095) | 0.026 | **fail** |
| Better Belt Balancer | one throttled | 0.245 [0.228..0.302] | 0.066 | 0.059 | 0.0000 (0.0 ms sampled) | 1550 / 1100 |  |  |  |
| plain splitter network (vanilla reference) | one throttled | 0.260 [0.248..0.300] | 0.068 | 0.071 | 0.0000 (0.0 ms sampled) | 1000 / 2200 | 1.06x (+0.016) | 0.018 | (reference) |

### 50 x 3:5

| balancer | outputs | wholeUpdate ms/tick median [min..max] | transportLines | entityUpdate | script ms/tick (ticklens, engine timer) | visible / hidden entities | vs BBB | noise | gate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| modular-balancer | all free | 0.444 [0.406..0.501] | 0.178 | 0.126 | 0.0000 (0.0 ms sampled) | 2100 / 10850 | 1.40x (+0.126) | 0.020 | **fail** |
| Better Belt Balancer | all free | 0.318 [0.301..0.341] | 0.079 | 0.108 | 0.0000 (0.0 ms sampled) | 2500 / 3200 |  |  |  |
| plain splitter network (vanilla reference) | all free | 0.385 [0.356..0.421] | 0.127 | 0.123 | 0.0000 (0.0 ms sampled) | 1600 / 7150 | 1.21x (+0.067) | 0.017 | (reference) |
| modular-balancer | one throttled | 0.463 [0.431..0.520] | 0.195 | 0.127 | 0.0000 (0.0 ms sampled) | 2100 / 10850 | 1.39x (+0.130) | 0.024 | **fail** |
| Better Belt Balancer | one throttled | 0.333 [0.302..0.406] | 0.086 | 0.108 | 0.0000 (0.0 ms sampled) | 2500 / 3200 |  |  |  |
| plain splitter network (vanilla reference) | one throttled | 0.383 [0.364..0.450] | 0.126 | 0.120 | 0.0000 (0.0 ms sampled) | 1600 / 7150 | 1.15x (+0.049) | 0.026 | (reference) |

### 50 x 8:3

| balancer | outputs | wholeUpdate ms/tick median [min..max] | transportLines | entityUpdate | script ms/tick (ticklens, engine timer) | visible / hidden entities | vs BBB | noise | gate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| modular-balancer | all free | 0.481 [0.469..0.554] | 0.187 | 0.151 | 0.0000 (0.0 ms sampled) | 3000 / 11200 | 1.30x (+0.112) | 0.030 | **fail** |
| Better Belt Balancer | all free | 0.369 [0.332..0.471] | 0.092 | 0.138 | 0.0000 (0.0 ms sampled) | 3550 / 3150 |  |  |  |
| plain splitter network (vanilla reference) | all free | 0.408 [0.399..0.439] | 0.121 | 0.146 | 0.0000 (0.0 ms sampled) | 2200 / 6000 | 1.11x (+0.039) | 0.027 | (reference) |
| modular-balancer | one throttled | 0.455 [0.436..0.543] | 0.181 | 0.127 | 0.0000 (0.0 ms sampled) | 3000 / 11200 | 1.36x (+0.120) | 0.029 | **fail** |
| Better Belt Balancer | one throttled | 0.335 [0.318..0.409] | 0.087 | 0.113 | 0.0000 (0.0 ms sampled) | 3550 / 3150 |  |  |  |
| plain splitter network (vanilla reference) | one throttled | 0.373 [0.350..0.424] | 0.109 | 0.122 | 0.0000 (0.0 ms sampled) | 2200 / 6000 | 1.11x (+0.038) | 0.022 | (reference) |

### 50 x 9:1

| balancer | outputs | wholeUpdate ms/tick median [min..max] | transportLines | entityUpdate | script ms/tick (ticklens, engine timer) | visible / hidden entities | vs BBB | noise | gate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| modular-balancer | all free | 0.258 [0.246..0.295] | 0.077 | 0.058 | 0.0000 (0.0 ms sampled) | 2900 / 4500 | 0.97x (-0.008) | 0.013 | pass |
| Better Belt Balancer | all free | 0.266 [0.252..0.287] | 0.079 | 0.062 | 0.0000 (0.0 ms sampled) | 3400 / 8400 |  |  |  |
| modular-balancer | one throttled | 0.207 [0.195..0.213] | 0.072 | 0.025 | 0.0000 (0.0 ms sampled) | 2900 / 4500 | 0.96x (-0.008) | 0.005 | pass |
| Better Belt Balancer | one throttled | 0.216 [0.205..0.224] | 0.075 | 0.023 | 0.0000 (0.0 ms sampled) | 3400 / 8400 |  |  |  |

### 50 x 17:2

| balancer | outputs | wholeUpdate ms/tick median [min..max] | transportLines | entityUpdate | script ms/tick (ticklens, engine timer) | visible / hidden entities | vs BBB | noise | gate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| modular-balancer | all free | 0.562 [0.537..0.611] | 0.270 | 0.135 | 0.0000 (0.0 ms sampled) | 5500 / 29050 | 1.36x (+0.148) | 0.034 | **fail** |
| Better Belt Balancer | all free | 0.414 [0.390..0.521] | 0.141 | 0.127 | 0.0000 (0.0 ms sampled) | 6450 / 20850 |  |  |  |
| modular-balancer | one throttled | 0.420 [0.398..0.497] | 0.189 | 0.093 | 0.0000 (0.0 ms sampled) | 5500 / 29050 | 1.26x (+0.087) | 0.022 | **fail** |
| Better Belt Balancer | one throttled | 0.334 [0.299..0.368] | 0.106 | 0.087 | 0.0000 (0.0 ms sampled) | 6450 / 20850 |  |  |  |

### 50 x 33:5

| balancer | outputs | wholeUpdate ms/tick median [min..max] | transportLines | entityUpdate | script ms/tick (ticklens, engine timer) | visible / hidden entities | vs BBB | noise | gate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| modular-balancer | all free | 1.600 [1.564..1.689] | 0.967 | 0.418 | 0.0000 (0.0 ms sampled) | 10900 / 72850 | 1.71x (+0.665) | 0.034 | **fail** |
| Better Belt Balancer | all free | 0.935 [0.878..0.965] | 0.392 | 0.355 | 0.0000 (0.0 ms sampled) | 12800 / 49800 |  |  |  |
| modular-balancer | one throttled | 1.461 [1.412..1.599] | 0.883 | 0.368 | 0.0000 (0.0 ms sampled) | 10900 / 72850 | 1.74x (+0.619) | 0.045 | **fail** |
| Better Belt Balancer | one throttled | 0.842 [0.804..0.903] | 0.350 | 0.310 | 0.0000 (0.0 ms sampled) | 12800 / 49800 |  |  |  |

### 4 x 64:64

| balancer | outputs | wholeUpdate ms/tick median [min..max] | transportLines | entityUpdate | script ms/tick (ticklens, engine timer) | visible / hidden entities | vs BBB | noise | gate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| modular-balancer | all free | 1.161 [1.076..1.199] | 0.770 | 0.226 | 0.0000 (0.0 ms sampled) | 2560 / 18708 | 2.33x (+0.664) | 0.039 | **fail** |
| Better Belt Balancer | all free | 0.497 [0.459..0.604] | 0.175 | 0.169 | 0.0000 (0.0 ms sampled) | 3072 / 4096 |  |  |  |
| modular-balancer | one throttled | 1.268 [1.181..1.348] | 0.858 | 0.233 | 0.0000 (0.0 ms sampled) | 2560 / 18708 | 2.48x (+0.756) | 0.036 | **fail** |
| Better Belt Balancer | one throttled | 0.512 [0.465..0.578] | 0.190 | 0.161 | 0.0000 (0.0 ms sampled) | 3072 / 4096 |  |  |  |

### 4 x 96:96

| balancer | outputs | wholeUpdate ms/tick median [min..max] | transportLines | entityUpdate | script ms/tick (ticklens, engine timer) | visible / hidden entities | vs BBB | noise | gate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| modular-balancer | all free | 4.400 [4.313..4.470] | 3.834 | 0.387 | 0.0000 (0.0 ms sampled) | 3840 / 54612 |  |  |  |
| Better Belt Balancer | all free | not supported (port limit 64) | | | | | | | |
| modular-balancer | one throttled | 4.489 [4.400..4.596] | 3.934 | 0.387 | 0.0000 (0.0 ms sampled) | 3840 / 54612 |  |  |  |
| Better Belt Balancer | one throttled | not supported (port limit 64) | | | | | | | |

### 4 x 128:128

| balancer | outputs | wholeUpdate ms/tick median [min..max] | transportLines | entityUpdate | script ms/tick (ticklens, engine timer) | visible / hidden entities | vs BBB | noise | gate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| modular-balancer | all free | 2.619 [2.549..2.727] | 1.936 | 0.484 | 0.0000 (0.0 ms sampled) | 5120 / 42516 |  |  |  |
| Better Belt Balancer | all free | not supported (port limit 64) | | | | | | | |
| modular-balancer | one throttled | 2.971 [2.900..3.081] | 2.304 | 0.479 | 0.0000 (0.0 ms sampled) | 5120 / 42516 |  |  |  |
| Better Belt Balancer | one throttled | not supported (port limit 64) | | | | | | | |

Computed verdict: fail at 2:3 all free (1.40x), 2:3 one throttled (1.39x), 3:5 all free (1.40x), 3:5 one throttled (1.39x), 8:3 all free (1.30x), 8:3 one throttled (1.36x), 17:2 all free (1.36x), 17:2 one throttled (1.26x), 33:5 all free (1.71x), 33:5 one throttled (1.74x), 64:64 all free (2.33x), 64:64 one throttled (2.48x)

## Not measured (stop rule)

- **Belt Balancer 3:** no benchmark saves were built. It is not part of the gate, which compares
  against BBB only. In the scout runs it worked at every ratio here, including 96:96 and 128:128.
  It split a throttled output's share equally, and it does Lua work every tick: it moves every item
  in Lua.
- **`load_time_with_200_balancers`** (Review Focus 1): not measured.
- **Rebuild hitch** (one full 64:64 group, and a flush of 10 groups): not measured.
  - `bench_add_output` in `bench/builders.lua` is ready for it: it adds an output to some copies
    and logs a profiled `balancer.flush()`.
  - F9 has the numbers for a single 64:64: 54-57 ms empty, 217-221 ms full.

## Caveats

- The `plain` reference is not a hand-built vanilla balancer. It has no visible belts between
  splitters, and the community blueprints named in the brief were not used.
- Everything ran on one machine in one session (2026-10-25). The saves of each ratio were
  benchmarked back to back to limit drift. Absolute numbers will differ on other machines; the
  ratios should vary less.
- The ticklens window ran at game speed 1, while the benchmark runs unthrottled.
