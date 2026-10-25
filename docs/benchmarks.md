# UPS gate: modular-balancer against Better Belt Balancer and Belt Balancer 3

Plan 3 Task 1 (2026-10-25). Factorio 2.1.23, vanilla preset, express tier everywhere.

## Outcome: per-balancer recirculation toggle (Plan 3 Task 3)

The user accepted the cost below and chose a per-balancer toggle (spec Update 2026-10-25 (2)).
Every balancer's settings window (click a block) has the checkbox **"Redistribute unused
shares"** ("남는 몫 되돌려 보내기"):

- **On (the default):** the recirculating network, the rows "recirculating, after" below. Every
  output stays equal even when some outputs take less than their share.
- **Off:** the plain network (`network.build(n, m, { recirc = false })`), the rows "plain (recirc
  off), after" below: 0.98x-1.07x BBB at 2:3 and 9:1 and, with all outputs free, at 8:3 and
  64:64; 1.08x-1.54x elsewhere. All outputs are still equal while they are all free; a slow
  output gives its unused share to its last-stage sibling only.

Turning it on or off rebuilds that balancer once, items kept (tests/game/lanes.lua
`toggle_recirc_on_full_balancer`). The setting travels with settings paste and blueprints, and a
merge keeps the larger group's setting. The release gate is now: zero per-tick script (met), plus
these numbers published.

## Verdict (round 2, after the network optimisation)

**Fail at 2:3, 3:5, 8:3, 17:2, 33:5 and 64:64**, with all outputs free and with one output
throttled. The recirculating network passes only at 9:1.

The user then decided to shrink the hidden network and measure again (follow-up to Task 1). This is
that second round. Per the stop rule nothing else was changed and no toggle was added.

- **Script time: met.** There is still no per-tick script.
- **Total update time: not met.** The optimisation made the hidden networks 6-25 % fewer
  splitters (17:2 recirculating 119 to 112, 2:3 plain 8 to 6; 9:1 is unchanged). The
  recirculating network now costs 1.27x-2.14x BBB's total update time with all outputs free and
  1.29x-2.11x with one throttled. It was 1.31x-2.93x before, in the same session.
- **Without recirculation ("how far from BBB?"):** the optimised plain network is close to BBB
  at 2:3 (1.01x free, 1.02x throttled) and 9:1 (1.05x, 0.98x), and with all outputs free only at
  8:3 (1.07x) and 64:64 (0.99x). Given the run-to-run spread of round 2 (below), these cells
  could go either way on an idle machine: they show parity within a few percent, not a firm tie
  or win. It is worse at:
  - 3:5 (1.08x, 1.17x);
  - 8:3 throttled (1.09x);
  - 17:2 (1.15x, 1.42x);
  - 33:5 (1.16x, 1.54x);
  - 64:64 throttled (1.11x).

  A recirculation toggle alone would therefore not pass the gate at every ratio.

### Summary (ratio to BBB, median of 10 runs; BBB pooled over 20 runs)

| ratio | outputs | recirculating before | recirculating after | plain before | plain after |
| --- | --- | --- | --- | --- | --- |
| 2:3 | free / throttled | 1.64x / 1.40x | 1.35x / 1.44x | 1.19x / 1.09x | **1.01x / 1.02x** |
| 3:5 | free / throttled | 1.31x / 1.42x | 1.27x / 1.42x | 1.33x / 1.33x | 1.08x / 1.17x |
| 8:3 | free / throttled | 1.36x / 1.41x | 1.27x / 1.29x | 1.18x / 1.06x | **1.07x** / 1.09x |
| 9:1 | free / throttled | **0.90x / 0.96x** | same network | **1.05x / 0.98x** | same network |
| 17:2 | free / throttled | 1.42x / 1.44x | 1.29x / 1.52x | 1.28x / 1.49x | 1.15x / 1.42x |
| 33:5 | free / throttled | 1.59x / 1.81x | 1.37x / 1.91x | 1.29x / 1.72x | 1.16x / 1.54x |
| 64:64 | free / throttled | 2.93x / 2.69x | 2.14x / 2.11x | **1.12x** / 1.32x | **0.99x** / 1.11x |

Bold: the difference to BBB is below 2 SE of the run-median means. That bound (about 4-5 % of
BBB) is the statistical noise of the 10 runs of one block only. The run-to-run spread in round 2
was larger: A/A deltas between two identical instances reached 15-35 % on some saves, and some
"after" cells came out slower than "before" although their networks are strictly smaller (2:3
throttled 1.40x to 1.44x, 17:2 throttled 1.44x to 1.52x, 33:5 throttled 1.81x to 1.91x, plain
8:3 throttled 1.06x to 1.09x). Read differences under about 10 % as unresolved, and the bold
cells as "close to BBB", not as a pass.

**Caveat: the machine was busy during round 2.** The user's desktop applications kept CPU load at
50-80 %, against an idle machine in round 1, so absolute times are about 20-35 % higher than in
round 1. The A/A deltas reached 15-35 % on some saves. Each ratio was therefore measured as one
block of back-to-back runs (BBB, the four variants, BBB again), and the BBB reference pools both
BBB runs. 17:2 free was measured again in full after a load spike. Ratios within a block are
comparable; absolute numbers across blocks and rounds are not.

### What changed in the network (`scripts/network.lua`, commit 572655f)

- **Benes cores.** Two butterflies in a row are built as a Benes network (2k - 1 stages): the second
  butterfly runs in reverse, so its first stage repeats the last stage of the first, and two
  splitters on the same pair of wires act as one. A plain 64:64 goes from 384 to 352 splitters.
- **fold().** A plain splitter whose two outputs feed the two inputs of one node is dropped. That
  node splits and draws equally anyway.
- **Stage order.** The recirculating network's input balancer F, and the front core of the plain
  network, run their stages in reverse. Their last stage then pairs neighbouring wires, which the
  next stage pairs too, and fold() removes it.
- **Every guarantee is unchanged.** The offline suite checks exact N:M, equal input draw under
  backpressure, throughput-unlimited for any subset (max flow and the splitter model), outputs equal
  for any input mix and keep-lanes / balance-lanes, exhaustive up to 8:8 plus 16:16, 3:16 and 16:3
  and sampled up to 64 (plus 100:3, 1:40). Since the review fix round these checks run in both
  modes, recirculating (the default) and plain (`recirc = false`). Recirculation with slow outputs
  is checked for the recirculating mode. It passes 43/43, including two new tests:
  - `benes_core_sizes`;
  - `no_redundant_splitter_pairs`.
- **Existing groups keep their networks.** A group is rebuilt only when its number of inputs or
  outputs changes, so groups from older saves keep the larger pre-optimisation networks (same
  guarantees, same storage format, no migration). The sizes and numbers here, and the README
  sizes, apply to groups built or resized after this change. A forced rebuild on load is not done
  because of the rebuild hitch (below).
- **In-game suites:** 181/181 (vanilla) and 183/183 (space-age).

Splitters / linked belts per network (counted in the saves; the buffer's merge splitter is
excluded):

| network | before | after | plain before | plain after | BBB |
| --- | --- | --- | --- | --- | --- |
| 2:3 | 32 / 125 | 26 / 101 | 8 / 33 | 6 / 25 | 4 + 3 lane / 16 (+4 belts) |
| 3:5 | 44 / 170 | 39 / 150 | 28 / 112 | 22 / 88 | 12 + 6 lane / 38 (+16 belts) |
| 8:3 | 46 / 175 | 38 / 143 | 24 / 93 | 19 / 73 | 12 + 8 lane / 38 (+16 belts) |
| 9:1 | 21 / 66 | 21 / 66 | 21 / 66 | 21 / 66 | 32 + 16 lane / 82 (+48 belts) |
| 17:2 | 119 / 459 | 112 / 431 | 143 / 559 | 120 / 467 | 80 + 32 lane / 196 (+128 belts) |
| 33:5 | 298 / 1 156 | 281 / 1 088 | 351 / 1 378 | 302 / 1 182 | 192 + 64 lane / 458 (+320 belts) |
| 64:64 | 960 / 3 714 | 864 / 3 330 | 384 / 1 538 | 352 / 1 410 | 192 + 64 lane / 576 (+320 belts) |

### Why the gap remains

Three ideas did not help:
- **Linked belts are not the cost.** A probe with 120 chains of 20 express splitters in series
  (`bench_edge_probe`) joined them three ways: directly (no belts), by one belt tile, or by a
  linked-belt pair (as builder.place does). transportLinesUpdate was 0.233, 0.257 and 0.244 ms,
  and wholeUpdate 0.586, 0.629 and 0.589 ms (raw/edge-*.json). The three are within the noise.
  Replacing linked belts by adjacency or plain belts would not pay, so the layout was not changed.
- **The recirculation stage cannot be made cheaper this way.** Its core G takes the L input lines
  plus one overflow wire per output (L >= M). Each overflow wire can carry a full belt (all outputs
  but one blocked), so the wires cannot be merged. G therefore spans at least 2M wires and needs two
  butterflies to stay throughput-unlimited.
- **G needs both butterflies.** With one butterfly, 10 offline tests fail: equal outputs, input
  draw, slow outputs and throughput.

Two structural limits remain:
- **The input balancer F is costly at awkward sizes.** At 33:5 it is a butterfly over 64 wires,
  already as large as BBB's whole network.
- **Throughput-unlimited costs more than one butterfly.** BBB's 64:64 is one butterfly (192
  splitters), which is not throughput-unlimited. The smallest throughput-unlimited 64:64 this
  generator builds is a Benes network of 352 splitters (whether a smaller one exists was not
  studied).

### Review Focus 1: `load_time_with_200_balancers`

200 x 8:3 (36 800 hidden entities, 1.78 MB of script storage), loaded three times with
`server_start`. The times are from the instance log: "Loading map" to "Hosting game" for the whole
map, and "Loading script.dat" to "Hosting game" for the script part (raw/load-times.txt).

| save | whole map load | script part | script.dat |
| --- | --- | --- | --- |
| harness only, no balancer | 0.165-0.197 s | 0.027-0.037 s | 42 KB |
| 200 modular-balancer 8:3 | 0.371-0.427 s | 0.089-0.111 s | 1.78 MB |
| 200 BBB 8:3 (reference) | 0.541-0.558 s | 0.334-0.349 s | 1.87 MB |

- Loading costs about 1 ms per balancer, of which 0.3 ms is the storage. This is a deserialisation
  cost, not a rebuild: on_load only re-registers the flush handler when work is pending.
- Load time grows with the save's size and no network is rebuilt on load. BBB's script part is
  3.5x longer (the cause was not investigated).

### Rebuild hitch

Save `hitch-64`: 11 x 64:64 with every sink stopped until full, 329 670 items, about 30 000 per
network. `bench_add_output` adds one output to some groups and times `balancer.flush()` with
`helpers.create_profiler` (raw/rebuild-hitch.txt):

| flush | duration |
| --- | --- |
| one full 64:64 group rebuilt (64:64 to 64:65) | 513 ms |
| ten full 64:64 groups rebuilt in one flush | 6 067 ms |

- Each rebuild carries about 30 000 items (F9: about 11 µs per item). Ten at once freeze the game
  for 6 s.
- This is Review Focus 5 (Task 5 `rebuild_cost_is_bounded`: bound the work per flush and spread it
  over ticks). The README's size note now gives these numbers.
- Measured on the busy machine, so the times are likely somewhat high; they are not strict
  bounds.
- Superseded by the staged rebuilds below (Task 5).

### Staged rebuilds (Plan 3 Task 5, `rebuild_cost_is_bounded`)

Since Task 5 the flush handler spends at most `balancer.tick_budget` work units per tick
(30 000, about 30 ms on an idle desktop; `builder.COST` and the scan/spill costs in
`scripts/balancer.lua`) on rebuilds, drains and spills. A rebuild:

1. generates the network in a tick of its own (it cannot be split);
2. places it a budget's worth of entities per tick while the old network keeps running;
3. switches every port to it and drains the sealed old network into it, item by item, over the
   next ticks.

A removed network is taken out and given away or spilled the same way. Everything is in
`storage` and counted in work units, never time, so a save made mid-rebuild finishes it after
loading, and multiplayer peers do the same work per tick.

Method:
- saves: `master-full64` (11 x 64:64, every sink stopped, 29 970 iron plates per network) and
  `master-unmerge` (4 x 64:64 fed with 12 kinds of stack-size-1 items: armor, vehicles, wagons,
  spidertron; 29 970 items per network, every one its own inventory slot);
- before = the code at 8d8b563, timing the one blocking flush;
- after = `bench_staged`, which times every handler call until no work is left
  (raw/rebuild-staged.txt);
- each run loads a fresh copy of the save. The machine was busy throughout (CPU load 50-85 %
  from other jobs), so absolute times are high and noisy, before and after alike.

| case | before: one flush | after: longest tick | after: median tick | after: ticks |
| --- | --- | --- | --- | --- |
| one full 64:64 gets a 65th output | 700 ms | 121 ms | 41 ms | 24 |
| ten full 64:64 get a 65th output in one flush | 8 102 ms | 177 ms | 43 ms | 219 |
| ten full 64:65 removed (nobody to take the items, spilled) | 4 947 ms | 77 ms | 42 ms | 142 |
| one full 64:64 of unmergeable items gets a 65th output | 1 649 ms | 83 ms | 29 ms | 24 |
| three full 64:64 of unmergeable items removed (spilled) | 314 382 ms | 62 ms | 27 ms | 98 |

- **The longest tick is network generation.** `network.build` for 64:65 takes 80-120 ms on this
  machine (64:64: about 20 ms; Task 1 measured 300:300 at about 200 ms offline). It runs in a
  tick of its own and cannot be split without making the generator resumable with its state in
  `storage`. Every other tick stays near the budget: 25-50 ms, with spikes to about 100 ms (GC,
  the machine's load).
- **Ten rebuilds at once:** the ten placements and drains run one after the other, about 220 ticks
  (3.6 s) in all, each tick within the budget except the ten generation ticks (100-180 ms here).
- **Unmergeable spill (3 x 30 000 stacks):** before, the spill piled every stack beyond 32 rings
  on one spot, and each further stack searched a free place through the pile: over five minutes
  frozen. Now a removed network spilled over several ticks keeps its search cursor and gets up to
  256 rings, so each stack costs about the same.
- The flush itself is bounded too: a group's scan is charged per port, groups over the budget
  wait for the next tick, and edges of removed groups over the budget are swapped back on a later
  tick (the removal of ten 64:65 groups: 1 290 edges).
- Mid-rebuild save and load (MCP instance, `master-full64` with every source stopped): 352 198
  items before; saved with one group's placement at operation 11 015 of 16 555 and another queued;
  352 198 after loading; the handler resumed, both groups finished as 64:65, 352 198 at the end,
  11 regions for 11 networks.

### Round 2 tables

From `python -I bench/tables2.py` (raw/r2-*.json, r2b-*.json). Variants: recirculating
(the default) and plain (`recirc = false`), each before (commit 70f1051) and after (572655f) the
optimisation.

#### 50 x 2:3

| variant | outputs | wholeUpdate ms/tick median [min..max] | vs BBB | noise | below 2 SE? | splitters / linked belts per network |
| --- | --- | --- | --- | --- | --- | --- |
| Better Belt Balancer | all free | 0.295 [0.265..0.349] (20 runs) | | | | 4 + 3 lane / 16 (+4 belts) |
| recirculating, before | all free | 0.483 [0.450..0.530] | 1.64x (+0.188) | 0.020 | **no** | 32 / 125 |
| recirculating, after | all free | 0.399 [0.354..0.421] | 1.35x (+0.104) | 0.018 | **no** | 26 / 101 |
| plain (recirc off), before | all free | 0.351 [0.304..0.379] | 1.19x (+0.057) | 0.018 | **no** | 8 / 33 |
| plain (recirc off), after | all free | 0.298 [0.264..0.322] | 1.01x (+0.004) | 0.016 | yes | 6 / 25 |
| Better Belt Balancer | one throttled | 0.291 [0.260..0.338] (20 runs) | | | | 4 + 3 lane / 16 (+4 belts) |
| recirculating, before | one throttled | 0.408 [0.353..0.458] | 1.40x (+0.117) | 0.025 | **no** | 32 / 125 |
| recirculating, after | one throttled | 0.418 [0.366..0.427] | 1.44x (+0.127) | 0.018 | **no** | 26 / 101 |
| plain (recirc off), before | one throttled | 0.318 [0.284..0.345] | 1.09x (+0.027) | 0.017 | **no** | 8 / 33 |
| plain (recirc off), after | one throttled | 0.297 [0.265..0.330] | 1.02x (+0.006) | 0.017 | yes | 6 / 25 |

#### 50 x 3:5

| variant | outputs | wholeUpdate ms/tick median [min..max] | vs BBB | noise | below 2 SE? | splitters / linked belts per network |
| --- | --- | --- | --- | --- | --- | --- |
| Better Belt Balancer | all free | 0.378 [0.334..0.426] (20 runs) | | | | 12 + 6 lane / 38 (+16 belts) |
| recirculating, before | all free | 0.496 [0.445..0.570] | 1.31x (+0.118) | 0.024 | **no** | 44 / 170 |
| recirculating, after | all free | 0.479 [0.447..0.594] | 1.27x (+0.101) | 0.034 | **no** | 39 / 150 |
| plain (recirc off), before | all free | 0.504 [0.481..0.562] | 1.33x (+0.126) | 0.021 | **no** | 28 / 112 |
| plain (recirc off), after | all free | 0.409 [0.375..0.430] | 1.08x (+0.031) | 0.016 | **no** | 22 / 88 |
| Better Belt Balancer | one throttled | 0.395 [0.323..0.478] (20 runs) | | | | 12 + 6 lane / 38 (+16 belts) |
| recirculating, before | one throttled | 0.561 [0.494..0.657] | 1.42x (+0.165) | 0.034 | **no** | 44 / 170 |
| recirculating, after | one throttled | 0.560 [0.483..0.628] | 1.42x (+0.164) | 0.034 | **no** | 39 / 150 |
| plain (recirc off), before | one throttled | 0.525 [0.438..0.589] | 1.33x (+0.129) | 0.037 | **no** | 28 / 112 |
| plain (recirc off), after | one throttled | 0.463 [0.441..0.511] | 1.17x (+0.068) | 0.025 | **no** | 22 / 88 |

#### 50 x 8:3

| variant | outputs | wholeUpdate ms/tick median [min..max] | vs BBB | noise | below 2 SE? | splitters / linked belts per network |
| --- | --- | --- | --- | --- | --- | --- |
| Better Belt Balancer | all free | 0.437 [0.386..0.531] (20 runs) | | | | 12 + 8 lane / 38 (+16 belts) |
| recirculating, before | all free | 0.595 [0.535..0.658] | 1.36x (+0.159) | 0.031 | **no** | 46 / 175 |
| recirculating, after | all free | 0.553 [0.519..0.653] | 1.27x (+0.116) | 0.031 | **no** | 38 / 143 |
| plain (recirc off), before | all free | 0.516 [0.503..0.569] | 1.18x (+0.080) | 0.023 | **no** | 24 / 93 |
| plain (recirc off), after | all free | 0.466 [0.429..0.574] | 1.07x (+0.029) | 0.031 | yes | 19 / 73 |
| Better Belt Balancer | one throttled | 0.413 [0.372..0.527] (20 runs) | | | | 12 + 8 lane / 38 (+16 belts) |
| recirculating, before | one throttled | 0.581 [0.538..0.625] | 1.41x (+0.168) | 0.025 | **no** | 46 / 175 |
| recirculating, after | one throttled | 0.533 [0.474..0.653] | 1.29x (+0.120) | 0.043 | **no** | 38 / 143 |
| plain (recirc off), before | one throttled | 0.437 [0.409..0.488] | 1.06x (+0.025) | 0.024 | **no** | 24 / 93 |
| plain (recirc off), after | one throttled | 0.449 [0.399..0.492] | 1.09x (+0.036) | 0.028 | **no** | 19 / 73 |

#### 50 x 9:1

| variant | outputs | wholeUpdate ms/tick median [min..max] | vs BBB | noise | below 2 SE? | splitters / linked belts per network |
| --- | --- | --- | --- | --- | --- | --- |
| Better Belt Balancer | all free | 0.340 [0.296..0.410] (20 runs) | | | | 32 + 16 lane / 82 (+48 belts) |
| recirculating, before | all free | 0.307 [0.288..0.330] | 0.90x (-0.033) | 0.017 | yes | 21 / 66 |
| recirculating, after (same network as before) | all free | 0.307 [0.288..0.330] | 0.90x (-0.033) | 0.017 | yes | 21 / 66 |
| plain (recirc off), before | all free | 0.358 [0.280..0.455] | 1.05x (+0.018) | 0.036 | yes | 21 / 66 |
| plain (recirc off), after (same network as before) | all free | 0.358 [0.280..0.455] | 1.05x (+0.018) | 0.036 | yes | 21 / 66 |
| Better Belt Balancer | one throttled | 0.265 [0.225..0.333] (20 runs) | | | | 32 + 16 lane / 82 (+48 belts) |
| recirculating, before | one throttled | 0.254 [0.220..0.269] | 0.96x (-0.012) | 0.017 | yes | 21 / 66 |
| recirculating, after (same network as before) | one throttled | 0.254 [0.220..0.269] | 0.96x (-0.012) | 0.017 | yes | 21 / 66 |
| plain (recirc off), before | one throttled | 0.259 [0.218..0.280] | 0.98x (-0.006) | 0.019 | yes | 21 / 66 |
| plain (recirc off), after (same network as before) | one throttled | 0.259 [0.218..0.280] | 0.98x (-0.006) | 0.019 | yes | 21 / 66 |

#### 50 x 17:2

| variant | outputs | wholeUpdate ms/tick median [min..max] | vs BBB | noise | below 2 SE? | splitters / linked belts per network |
| --- | --- | --- | --- | --- | --- | --- |
| Better Belt Balancer | all free | 0.356 [0.321..0.412] (20 runs) | | | | 80 + 32 lane / 196 (+128 belts) |
| recirculating, before | all free | 0.506 [0.450..0.596] | 1.42x (+0.150) | 0.031 | **no** | 119 / 459 |
| recirculating, after | all free | 0.461 [0.433..0.523] | 1.29x (+0.105) | 0.021 | **no** | 112 / 431 |
| plain (recirc off), before | all free | 0.455 [0.407..0.489] | 1.28x (+0.099) | 0.020 | **no** | 143 / 559 |
| plain (recirc off), after | all free | 0.409 [0.377..0.438] | 1.15x (+0.053) | 0.017 | **no** | 120 / 467 |
| Better Belt Balancer | one throttled | 0.314 [0.272..0.421] (20 runs) | | | | 80 + 32 lane / 196 (+128 belts) |
| recirculating, before | one throttled | 0.454 [0.399..0.583] | 1.44x (+0.140) | 0.043 | **no** | 119 / 459 |
| recirculating, after | one throttled | 0.478 [0.400..0.507] | 1.52x (+0.163) | 0.031 | **no** | 112 / 431 |
| plain (recirc off), before | one throttled | 0.467 [0.394..0.488] | 1.49x (+0.153) | 0.030 | **no** | 143 / 559 |
| plain (recirc off), after | one throttled | 0.448 [0.368..0.514] | 1.42x (+0.133) | 0.035 | **no** | 120 / 467 |

#### 50 x 33:5

| variant | outputs | wholeUpdate ms/tick median [min..max] | vs BBB | noise | below 2 SE? | splitters / linked belts per network |
| --- | --- | --- | --- | --- | --- | --- |
| Better Belt Balancer | all free | 0.960 [0.820..1.379] (20 runs) | | | | 192 + 64 lane / 458 (+320 belts) |
| recirculating, before | all free | 1.529 [1.303..2.034] | 1.59x (+0.569) | 0.161 | **no** | 298 / 1156 |
| recirculating, after | all free | 1.310 [1.206..1.449] | 1.37x (+0.351) | 0.084 | **no** | 281 / 1088 |
| plain (recirc off), before | all free | 1.241 [1.172..1.520] | 1.29x (+0.281) | 0.105 | **no** | 351 / 1378 |
| plain (recirc off), after | all free | 1.117 [0.980..1.301] | 1.16x (+0.157) | 0.091 | **no** | 302 / 1182 |
| Better Belt Balancer | one throttled | 0.797 [0.707..1.112] (20 runs) | | | | 192 + 64 lane / 458 (+320 belts) |
| recirculating, before | one throttled | 1.447 [1.307..1.781] | 1.81x (+0.650) | 0.127 | **no** | 298 / 1156 |
| recirculating, after | one throttled | 1.519 [1.315..1.609] | 1.91x (+0.721) | 0.087 | **no** | 281 / 1088 |
| plain (recirc off), before | one throttled | 1.372 [1.233..1.904] | 1.72x (+0.575) | 0.140 | **no** | 351 / 1378 |
| plain (recirc off), after | one throttled | 1.224 [1.161..1.546] | 1.54x (+0.427) | 0.096 | **no** | 302 / 1182 |

#### 4 x 64:64

| variant | outputs | wholeUpdate ms/tick median [min..max] | vs BBB | noise | below 2 SE? | splitters / linked belts per network |
| --- | --- | --- | --- | --- | --- | --- |
| Better Belt Balancer | all free | 0.423 [0.349..0.710] (20 runs) | | | | 192 + 64 lane / 576 (+320 belts) |
| recirculating, before | all free | 1.238 [0.959..1.369] | 2.93x (+0.815) | 0.096 | **no** | 960 / 3714 |
| recirculating, after | all free | 0.904 [0.706..1.236] | 2.14x (+0.481) | 0.125 | **no** | 864 / 3330 |
| plain (recirc off), before | all free | 0.472 [0.442..0.793] | 1.12x (+0.049) | 0.085 | yes | 384 / 1538 |
| plain (recirc off), after | all free | 0.418 [0.350..0.578] | 0.99x (-0.005) | 0.068 | yes | 352 / 1410 |
| Better Belt Balancer | one throttled | 0.467 [0.381..0.596] (20 runs) | | | | 192 + 64 lane / 576 (+320 belts) |
| recirculating, before | one throttled | 1.258 [1.062..1.785] | 2.69x (+0.791) | 0.127 | **no** | 960 / 3714 |
| recirculating, after | one throttled | 0.985 [0.906..1.120] | 2.11x (+0.518) | 0.052 | **no** | 864 / 3330 |
| plain (recirc off), before | one throttled | 0.615 [0.495..0.710] | 1.32x (+0.148) | 0.049 | **no** | 384 / 1538 |
| plain (recirc off), after | one throttled | 0.517 [0.470..0.649] | 1.11x (+0.050) | 0.041 | **no** | 352 / 1410 |

- recirculating, before: more than 2 SE above BBB at 2:3 all free (1.64x), 2:3 one throttled (1.40x), 3:5 all free (1.31x), 3:5 one throttled (1.42x), 8:3 all free (1.36x), 8:3 one throttled (1.41x), 17:2 all free (1.42x), 17:2 one throttled (1.44x), 33:5 all free (1.59x), 33:5 one throttled (1.81x), 64:64 all free (2.93x), 64:64 one throttled (2.69x)
- recirculating, after: more than 2 SE above BBB at 2:3 all free (1.35x), 2:3 one throttled (1.44x), 3:5 all free (1.27x), 3:5 one throttled (1.42x), 8:3 all free (1.27x), 8:3 one throttled (1.29x), 17:2 all free (1.29x), 17:2 one throttled (1.52x), 33:5 all free (1.37x), 33:5 one throttled (1.91x), 64:64 all free (2.14x), 64:64 one throttled (2.11x)
- plain (recirc off), before: more than 2 SE above BBB at 2:3 all free (1.19x), 2:3 one throttled (1.09x), 3:5 all free (1.33x), 3:5 one throttled (1.33x), 8:3 all free (1.18x), 8:3 one throttled (1.06x), 17:2 all free (1.28x), 17:2 one throttled (1.49x), 33:5 all free (1.29x), 33:5 one throttled (1.72x), 64:64 one throttled (1.32x)
- plain (recirc off), after: more than 2 SE above BBB at 3:5 all free (1.08x), 3:5 one throttled (1.17x), 8:3 one throttled (1.09x), 17:2 all free (1.15x), 17:2 one throttled (1.42x), 33:5 all free (1.16x), 33:5 one throttled (1.54x), 64:64 one throttled (1.11x)

The rest of this document is round 1, before the optimisation, on an idle machine.

## Round 1 verdict (before the optimisation)

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

## Method (both rounds)

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

## Round 1 tables

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

## Not measured in round 1 (stop rule)

Round 2 measured `load_time_with_200_balancers` and the rebuild hitch (above).

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
