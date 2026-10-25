# Feasibility findings

Measured in Factorio 2.1.23 with fdev (`fdev test`, MCP `server_start` / `exec_lua` /
`screenshot`).

Spike code lives in `spikes/`. It loads only when the hidden startup setting `mb-spikes` is on.
That setting is forced on when two things hold: the git-ignored file `spikes/local-enable.lua`
exists (it returns `true`, or `{ variant = "<name>" }` to pick a prototype variant), and the dev
gate `mb-dev` is on (the `factorio-test` mod enabled and the dev marker `tests/dev.lua` present,
Plan 2 Task 5). Otherwise it is forced off. See `settings.lua`.

Commands:

- `fdev test modular-balancer [--preset space-age]` runs the spike tests. Every result is logged
  with the prefix `MB-SPIKE` in the test instance's `factorio-current.log`. Logs of the runs
  behind this file: `feasibility/f1-results-vanilla.txt` (express) and
  `feasibility/f1-results-space-age.txt` (turbo).
- `bash spikes/multi_belt/repro-load-errors.sh` reproduces the prototype-stage errors. Its
  output is in `feasibility/f1-load-errors.txt`.

## F1: several belts per 1x1 block (spike S1)

**Result: possible, but not on the block's own tile.**

- 2.1 allows exactly one belt-connectable entity per tile. This is enforced both when prototypes
  load and at runtime.
- So a block takes a belt on each free side by putting the interface on the *player's belt
  tile* next to the block. That belt tile is swapped for an "edge": a linked belt of the same
  belt tier, linked into the hidden network.
- Measured: an input on one side and an output on another at full belt speed, and two in plus
  two out on all four sides at once, with no throughput loss (45/45 items/s express, 60/60
  turbo).

### Why the block tile cannot hold more than one interface (measured)

**Prototype stage.** The game refuses to load. Each variant is in `spikes/multi_belt/data.lua`,
selected by `mb-spikes-variant`. Exact errors (`Util.cpp:81`, from `feasibility/f1-load-errors.txt`):

| variant | collision masks tried | error |
| --- | --- | --- |
| `custom-layers` | linked belt per side, `{ layers = { mb_spike_<side> = true } }` | `entity prototype "mb-spike-var-lb-e" (linked-belt) collision_mask(Modifications: Modular Balancer) must collide with entity prototype "transport-belt" (transport-belt) collision_mask.` |
| `belt-layer-subsets` | linked belt per side, a different layer of the vanilla belt mask each (`floor` / `meltable` / `transport_belt` / `water_tile`): each one collides with transport belts, and no two sides share a layer | `entity prototype "mb-spike-var-lb-n" (linked-belt) collision_mask(Modifications: Modular Balancer) must collide with entity prototype "mb-spike-var-lb-e" (linked-belt) collision_mask(Modifications: Modular Balancer).` |
| `not-colliding-with-itself` | one shared mask (the vanilla belt layers) with `not_colliding_with_itself = true` | `entity prototype "mb-spike-var-lb-e" (linked-belt) collision_mask(Modifications: Modular Balancer) must collide with entity prototype "mb-spike-var-lb-e" (linked-belt) collision_mask(Modifications: Modular Balancer).` |
| `tiles-only` | the vanilla belt layers with `colliding_with_tiles_only = true` | `entity prototype "mb-spike-var-lb-e" (linked-belt) collision_mask(Modifications: Modular Balancer) must collide with entity prototype "transport-belt" (transport-belt) collision_mask.` |
| `loader-custom-layers` | loader-1x1 per side, `{ layers = { mb_spike_ld_<side> = true } }` | `entity prototype "mb-spike-var-ld-e" (loader-1x1) collision_mask(Modifications: Modular Balancer) must collide with entity prototype "transport-belt" (transport-belt) collision_mask.` |

So in 2.1 every belt-connectable prototype must collide with every other one, itself included.
This is the "closed collision behaviour" that Better Belt Balancer's 0.2.0 changelog refers to.

A smaller collision box is ruled out by the API itself. `TransportBeltConnectablePrototype.collision_box`
says these entities "should occupy more than half of every tile the entity covers", so two of
them cannot share a tile that way either.

**Runtime.** Tested in FactorioTest (`spikes/multi_belt/test.lua`) on a tile that already holds
a linked belt:

- `LuaSurface::create_entity` of a second linked belt returns nil.
- `LuaEntity::clone` onto the tile returns nil.
- `LuaEntity::teleport` onto the tile returns false.
- A second loader-1x1 on a loader tile is refused by `create_entity`.

Non-belt entities (the block, a linked chest) can share the tile with one belt-connectable
entity.

### Candidates

| | candidate | placeable | belts connect | throughput (items/s) | test |
| --- | --- | --- | --- | --- | --- |
| a | several hidden linked belts on the block tile, disjoint collision layers | no: prototype errors (above), and runtime refuses stacking | - | - | `spike_stacked_linked_belts_refused` |
| b | loader-1x1 per side on the block tile into a shared hidden chest | no: prototype error (`loader-custom-layers`), and runtime refuses a second loader on the tile | - | - | `spike_stacked_loaders_refused` |
| c | the visible block is itself belt-connectable (linked belt with `allow_side_loading`) | yes | inputs only. The back and both sides feed the network, but nothing can leave to the east: a linked belt is one-way, and side-loaded inputs fill one lane only | east belt received 0 items in 600 ticks | `spike_block_as_belt_input_and_output_on_one_tile (no output)` |
| c' | other 1x1 belt-connectables (`lane-splitter`, `underground-belt`, `loader-1x1`) as the block | not tested | same limit as (c): each has one front, so a single entity on the tile has at most one output face, and that output cannot come from the network | - | - |
| d | from the changelog, 2.1.15: "Fixed a crash when rendering linked belt without structure sprites", so a linked belt with no structure draws as a plain belt. No 2.1 entry adds a way to stack belt-connectables. Used by (e) | - | - | - | - |
| e | **edge interface**: the player's belt tile next to the block becomes a linked belt of the same tier, linked to the network. The block tile holds no belt entity | yes | yes, each edge has exactly one belt neighbour | 45.00 express / 60.00 turbo with one in and one out; four sides (2 in, 2 out): 45.00 + 45.00 / 60.00 + 60.00 | `spike_edge_input_and_output_on_one_tile`, `spike_edge_throughput`, `spike_edge_four_sides` |
| e+ | **hybrid**: the block tile holds one linked belt for a side whose neighbour is not a plain belt (here an underground exit); the other sides are edges | yes | yes. The block-tile linked belt has 1 input and 0 outputs (no cross-talk with the edges) | 45.00 + 45.00 / 60.00 + 60.00 on four sides | `spike_hybrid_four_sides` |

How these were measured:

- **Inserter feed** (infinity chest, burner inserter, west belt): the first item reached the east
  belt after 84 ticks (express) / 75 ticks (turbo).
- **Throughput**: measured over 1 200 ticks after a 600-tick warm-up. Fed by a loader from an
  infinity chest, counted in a steel chest.
- **Network stand-in**: each input edge is linked straight to an output edge, or through a short
  hidden chain of linked belt, belts and linked belt. The real splitter network is Tasks 3-5.

### Edge behaviour (measured)

All with express in vanilla and turbo in Space Age; same results in both.

**1x8 row** (`spike_edge_row_1x8_eight_in_three_out`): a 1x8 column of blocks with 8 input edges
on the west face and 3 output edges on the east face.

- Every input edge has exactly 1 input and 0 outputs, and every output edge 0 inputs and 1
  output. No edge connects to the edge on the next block.
- The 3 outputs each carry 45.00 / 60.00 items/s, with 3 of the 8 inputs linked to them.
- The 8:3 *balancing* through a real network is not measured here (Tasks 4-5).

**Belt tile shared by two blocks** (`spike_shared_tile_internal_link`): block A's output tile
points straight into block B.

- One linked belt cannot be both A's output edge and B's input edge.
- Rule: an **internal link**. A's network output linked belt is connected directly to B's
  network input linked belt. The shared tile is left as a plain belt; it has 0 belt neighbours,
  and its items stay on it, so nothing is lost.
- Measured: the chain runs at 45.00 / 60.00 items/s, and the shared tile is unchanged (its
  1 item is still there).
- Plan 2 may move items on such a tile into B's network when it links them.
- A tile is only ever an input of the block it points into, and only an output of the block it
  points straight away from. So "both" can only happen with the two blocks on opposite sides of
  the tile, and this rule covers it.

**Two tiles between blocks** (`spike_two_tile_gap_edges_chain`): each tile is an ordinary edge.
A's output edge feeds B's input edge directly at 45.00 / 60.00 items/s.

**Side-fed output tile** (`spike_output_edge_side_loading`): a foreign belt points into the side
of an output edge.

- With `allow_side_loading = false`: 0 foreign items and 0 belt inputs.
- With side loading allowed: 208 / 283 foreign items merged into the output in 600 ticks.
- Rule: **output edges never allow side loading**, and a side-fed tile is not treated as an
  output.
- Input edges allow side loading, like the belt they replace: side-loaded items go into the
  network on one lane.

**Block-tile interface** (`spike_block_tile_interface_refuses_side_loading`): it must have
`allow_side_loading = false`. An underground exit pointing into its side then does not connect:
1 input, 0 foreign items.

**Swapping a tile keeps its items.** An edge line is half a tile long (`line_length` 0.5), so a
full belt tile does not fit on it. The swap rule, applied in order to each item:

1. onto the edge at the item's own position, if that position is on the edge and free;
2. else onto the linked partner (the network side), if it has room;
3. else force-inserted at the front of the edge with `LuaTransportLine::force_insert_at`
   (squashed, never dropped).

Measured:

- **Partner with room** (`spike_edge_swap_keeps_items`): 4 on the edge, 4 on the partner,
  8 of 8 kept.
- **Partner full**, the normal case when a belt is attached to a backed-up balancer
  (`spike_edge_swap_partner_full_conserves_items`):
  - 10 items on the tile and 30 on the full network side.
  - After the swap: 4 on the edge, 6 forced, 40 of 40 present.
  - After opening the line, exactly 40 arrived and 0 were left: no loss, no duplication.
- **Backed-up line still being fed** from a finite chest of 400 plates
  (`spike_edge_swap_in_backed_up_line_conserves_items`): swapped mid-run, and exactly 400 of 400
  arrived.
- **Belt stacks** (`spike_edge_swap_keeps_belt_stacks`): a stack of 4 stays a stack of 4 (items
  are re-inserted with `belt_stack_size`).

**Mining** (`spike_edge_mines_to_belt_item`): `LuaEntity::mine` on an edge gives 1 belt item of
the edge's tier plus the item that was on it.

**Blueprints** (`spike_edge_blueprint_records`):

- A blueprint of an edge records the edge entity itself (`mb-spike-edge`), not a belt.
  `placeable_by` does not change that. Pasted away from a block, it would be an orphan,
  unlinked linked belt.
- A script can rewrite the entry to the belt with `LuaItemCommon::set_blueprint_entities`
  (measured: the rewritten blueprint holds only belts).
- Plan 2 does this in `on_player_setup_blueprint`. The edge is rebuilt when the pasted belt
  touches a block.

**Fast-replace and upgrades** (`spike_edge_fast_replace`). The vanilla linked belt is in
`fast_replaceable_group = "linked-belts"`.

- In that group, `can_fast_replace` with a belt over the edge is false and `create_entity`
  with `fast_replace` is refused. A player cannot drag-build a belt over an edge.
- An upgrade planner rule "express belt -> turbo belt" does not select edges (a different
  entity), so after upgrading a line the edge stays at the old tier, and that belt runs at the
  old speed until the mod reacts.
- In `fast_replaceable_group = "transport-belt"` (`mb-spike-edge-frg`), a belt replaces the
  edge. `can_fast_replace` is true, the edge becomes invalid, and the link is gone. Plan 2 would
  have to re-swap on `on_built_entity`.
- Plan 2 chooses one. My suggestion: keep the edges in their own group, give them
  `next_upgrade` chains per belt tier, and re-swap when a block's neighbour belt is upgraded.

### Looks

Screenshots, express tier, vanilla graphics. Taken on an MCP `server_start` instance with
`exec_lua` builds, not by the tests:

- `feasibility/f1-edge-hatch-four-sides.jpg`: edges built from `mb-spike-lb` (the vanilla
  linked-belt prototype at express speed, *with* its hatch structure) on all four sides of a
  block. It reads as one machine taking four belts. `mb-spike-edge` itself has
  `structure = nil`, so this picture shows what an edge looks like *with* a structure sprite.
- `feasibility/f1-edge-plain-four-sides.jpg`, `feasibility/f1-edge-plain-saturated.jpg`: edges
  built from `mb-spike-edge` (no structure sprite). The belt is drawn only on the half tile away
  from the block, leaving a half-tile gap before the block, so the edge needs a structure
  sprite (a hatch or a housing lip).
- `feasibility/f1-block-tile-linked-belt.jpg`: the Better Belt Balancer way, for comparison:
  one linked belt on the block tile under the block sprite, and the belt runs into the block.

### Chosen design (F1)

**The visible block.** A non-belt-connectable building (here `simple-entity-with-owner` with
mask `item`, `player`, `is_object`). Its tile can hold at most one hidden linked belt and any
number of non-belt entities (such as the Task 3 proxy chest).

**Edge interfaces, one per attached belt** (the default for every side).

- When a plain `transport-belt` points straight into a block (input) or starts next to it
  pointing straight away (output), its tile is swapped for an edge linked belt.
- The edge has:
  - `linked_belt_type` `input` or `output`;
  - the same direction and speed as the belt it replaces;
  - `minable.result` set to the replaced belt's item.
- Input edges allow side loading. Output edges do not.
- The edge is linked to the network's input or output linked belt with
  `connect_linked_belts`.
- Items on the swapped tile follow the three-step swap rule above.
- Visually, the player's belt runs into a hatch at the block's face. Plan 2 graphics may
  replace the hatch.

**At most one block-tile interface**, for a side whose neighbour cannot be swapped (an
underground belt, a splitter, another mod's belt-connectable).

- It is a hidden linked belt on the block tile facing that side, with
  `allow_side_loading = false`.
- A second non-swappable neighbour on the same block is refused with a message.
- The block-tile interface never faces a shared tile.

**Between two blocks:**

- one belt tile: an internal link between the two networks, and the tile stays a plain belt;
- two or more tiles: ordinary edges at each end.

A block takes up to four belts (all edges), with any mix of inputs and outputs.

### Concerns for Plan 2

- **Swapped entities in the player's belt lines.** The edge is an entity the mod swaps in and
  out of the player's belt line. Plan 2 must:
  - swap it back to the original belt when the block or the balancer goes away;
  - rewrite blueprints in `on_player_setup_blueprint`;
  - handle copy-paste, undo/redo, ghosts and rotation;
  - handle upgrades (the edge does not follow an upgrade planner, see above).
- **One edge prototype per belt prototype.** One input and one output edge are needed per
  transport-belt prototype, modded belts included. They are generated in `data-final-fixes`, at
  that belt's speed, mining back to that belt's item. That input or output then runs at
  min(block tier, belt tier).
- **Curves.** A belt that turns into the block on its last tile has no straight edge
  equivalent. Either face the edge toward the feeding belt (full throughput, looks straight) or
  refuse the curve.
- **Squashed items after a swap.** A swap into a full network squashes up to half a tile of
  items onto the edge with `force_insert_at`. Measured to drain without loss, but those items
  sit closer together than normal until they move.
- **Shorter buffer.** An edge line is half a tile, so the belt line holds half a tile less than
  with a plain belt there. No throughput effect was measured.

## F2-F5: hidden surface, inserter access, inserter input, lane balancing (spike S2)

Code: `spikes/hidden_surface/` (`data.lua`, `test.lua`, and `save_load.lua` for the MCP
save/load check), same gating as S1. Logs of the runs behind this section:
`feasibility/f2-f5-results-vanilla.txt` (express, 45 items/s) and
`feasibility/f2-f5-results-space-age.txt` (turbo, 60 items/s). The save/load checks are in
`feasibility/f2-save-load.txt`. Where a cell shows two numbers, they are express / turbo.

Setup used by every test: the player's side is `nauvis` (a cleared area with lab tiles). The
network side is a surface made with `game.create_surface`, `LuaSurface::generate_with_lab_tiles`
and `LuaForce::set_surface_hidden(surface, true)` for the player force
(`LuaForce::get_surface_hidden` reads back true).

F1's interface matters for F3: the recommended inserter port (below) is a linked belt on the
block tile, and F1 allows only one belt-connectable entity there. A block that needs F1's
block-tile interface (a non-swappable neighbour) cannot also have an inserter port.

### F2: linked belts across surfaces

**Result: no throughput cost, and they survive save and load.**

- `linked_belt_cross_surface_throughput`: the same chain (source, input linked belt, output
  linked belt, 6 belts, input linked belt, output linked belt, sink) built once with its middle
  on the hidden surface and once all on nauvis. Over 3 600 ticks after a 600-tick warm-up:
  45.000 vs 45.000 items/s (express), 60.000 vs 60.000 (turbo). 0 % difference.
- Save and load, twice (MCP `server_start` with `factorio-test` in `portal_mods`, `exec_lua`,
  `game.server_save`, `server_stop`, `server_start` from the save):
  - Run 1 (express, by hand): a ring of 4 linked belts and 8 belts across nauvis and the
    hidden surface with 32 plates. After the load, the links, all 32 items with identical
    per-entity counts, and the hidden flag were unchanged, and the ring still circulated
    1 000 ticks later. The mod's prototypes changed between save and load in this run.
  - Run 2 (turbo, scripted with `spikes/hidden_surface/save_load.lua`, nothing changed
    between save and load): the same ring plus a belt port (the F3 design) with 8 items of
    two kinds and an inserter whose `pickup_target` was written. After the load: identical
    counts (ring 19 + 13, port 4 + 4), identical links, still hidden, `pickup_target`
    unchanged. Then the port inserter took all 8 items and the ring kept circulating.
- For the restart, `server_start`'s `save` needs the absolute path
  `E:\factorio-dev\instances\<name>\saves\<save>.zip`.

### F3: inserter access

**Result: exact with a belt port. The first design, a proxy container over a buffer chest, is
exact only for one item type. The stop rule does not apply, because an exact design exists.**

#### The two designs

- **Chest port** (round 1's recommendation): one network output ends in a loader into a
  buffer chest on the hidden surface, and the visible block is a proxy container whose
  `proxy_target_entity` is that chest. The vanilla `proxy-container` accepts a target on
  another surface (`inserter_takes_from_proxy_of_hidden_chest`: 100 of 100 plates taken
  through it). Variants measured: `chest1` (1 slot), `chest2` (2 slots), `filtered` (2 slots,
  `inventory_type = "with_filters_and_bar"`, one slot per item set with
  `LuaInventory::set_filter`, which needs the items known in advance).
- **Belt port** (recommended): one network output ends in a hidden input linked belt, linked to
  an output linked belt on the block tile, under the visible block (a non-belt entity with
  the F1 block mask). The port faces a side of the block and is a dead end: items stop at its
  end. Inserters next to the block pick from it (their default `pickup_target` on that tile is
  the linked belt). It behaves like a vanilla belt that ends at the inserters: each lane on its
  own, and an inserter picks only the items it needs from the tile.
- Control: `plain`, no port at all. The splitter output ends in a plain dead-end belt on the
  same surface as the consumer. It shows what vanilla belts do in the same situation.

Test rig (`build_rig` in `test.lua`): a splitter on the hidden surface, fed from the west,
with output A to a belt sink and output B to the port. A correct port gives B exactly what a
belt output would get: the same amount as A, per item.

#### One item type: partial demand, restart, backpressure (`inserter_share_phases_<port>`)

Three bulk inserters on the block. Phases of 3 600 ticks each, after a 600-tick warm-up.
B counts everything that left through the port: the inserters' chests, their hands, the
buffer or the port belt. Items/s, express / turbo:

| phase | chest1: A | chest1: B | belt: A | belt: B |
| --- | --- | --- | --- | --- |
| inserters free | 22.500 / 30.000 | 22.500 / 30.000 | 22.500 / 30.000 | 22.500 / 30.000 |
| slow: 1 inserter, hand size 1 | 42.500 / 57.500 | 2.500 / 2.500 | 42.283 / 57.267 | 2.717 / 2.717 |
| restarted (all 3, full hands) | 22.500 / 30.000 | 22.500 / 30.000 | 22.500 / 30.000 | 22.500 / 30.000 |
| output A blocked | 0 | 45.000 / 60.000 | 0 | 41.000 / 47.000 |

- Partial demand: the inserter gets exactly what it takes, and A gets the rest
  (A + B = 45.000 / 60.000 in every case except the belt port at turbo, 59.983, which is one
  item in transit over the window).
- After the restart the split is exactly half again, so any extra the buffer gave at the start
  of that phase is gone within the 600-tick warm-up.
- With A blocked the inserters get everything up to their own speed. From a belt, three bulk
  inserters manage 41 / 47 items/s, against 45 / 60 from a chest.
- Per inserter (free phase), the three inserters' chests held 336 / 338 / 842 (chest1) and
  300 / 912 / 300 (belt), so one inserter takes about half of the block's share. That is fine
  for exactness, but the user may notice it.

#### Two item types (`mixed_share_<feed>_<port>`, `mixed_assembler_<feed>_<port>`)

Feeds: `lanes` (iron on the left lane, copper cable on the right, one full lane each),
`lanes_late` (the same, with the cable lane starting 900 ticks after the iron lane), `mixed`
(iron and cable in irregular clumps on one lane, dropped by five bulk inserters),
`alternating` (iron and cable strictly alternating on one lane, from a side-loaded yellow
column).

Share with three free inserters (items/s, A / B per item, express; turbo in the logs):

| feed | port | iron A / B | cable A / B |
| --- | --- | --- | --- |
| lanes | chest1 | 11.250 / 11.250 | **15.000 / 7.500** |
| lanes | chest2 | 11.250 / 11.250 | 11.250 / 11.250 |
| lanes | filtered | 11.250 / 11.250 (turbo: **30.000 / 0**) | 11.250 / 11.250 |
| lanes | belt | 11.250 / 11.250 | 11.250 / 11.250 |
| mixed | all four | 7.100 / 7.117-7.133 | 4.150 / 4.133 |
| alternating | belt | **7.500 / 0** | **0 / 7.500** |

- `chest1` with two lanes: while the one slot holds iron, cable cannot enter, the cable lane
  backs up through the loader, and the splitter sends that cable to A. The block gets half its
  cable share (turbo: 5 vs 25).
- `filtered` at turbo: the cable slot is refilled so fast that the inserters always find cable
  and never take iron; the full iron slot backs the iron lane up, and all iron goes to A. Which
  item an inserter takes from a chest decides the per-item share, so a chest port is not exact
  per item even with filters.
- `alternating`: the splitter alternates per item, so a strictly alternating lane sends all
  iron to one output and all cable to the other. This is vanilla splitter behaviour (counts
  are exact, item types are not) and has nothing to do with the port. **It matters for Task 5
  (`mixed_items_keep_lanes`, Review Focus 3, "no item type is starved")**: a perfectly
  alternating single lane can starve an item type on an output of any splitter network.

Assembler that needs both items (electronic circuit: 1 iron plate + 3 copper cable, max 1.5
circuits/s), one inserter from the block, circuits/s over 3 600 ticks after 1 200 (express / turbo
where they differ):

| feed | chest1 | chest2 | filtered | belt | plain (vanilla) |
| --- | --- | --- | --- | --- | --- |
| lanes | **0** (slot holds 100 iron) | 1.500 | 1.500 | 1.500 | 1.500 |
| lanes_late | **0** | **0** (both slots iron) | 1.500 | 1.500 | 1.500 |
| mixed (one lane) | 0 | 0.050 / 0.117 | 0.033 / 0.167 | 0 | 0 |
| alternating (one lane) | - | - | - | 0 | 0 |

- With two lanes, the belt port never starves the assembler, like a vanilla belt. `chest1`
  deadlocks at once. `chest2` deadlocks when one item arrives first and fills both slots.
  `filtered` works only with the items known and set in advance.
- With both items on one lane, every design starves, the vanilla dead-end belt included: the
  item at the front of the lane is one the assembler does not need. The belt port is no worse
  than vanilla here.

**Recommended design: the belt port.** For each block with taking inserters, one network
output ends in a hidden input linked belt linked to an output linked belt on the block tile.
It is exact per lane and per item exactly where a vanilla belt is, and needs no knowledge of
the items.

#### Belt port details (measured)

- `belt_port_ignores_edges`: all four combinations of an output or input port (facing west)
  with F1 output or input edges on all four sides: 0 belt neighbours on the port and on
  every edge. A port next to F1 edges of either type connects to nothing. Other neighbours
  are covered in the next item.
- **What an output port does to the entity in front of it** (`belt_port_front_neighbours`).
  The port is fed by a saturated hidden linked belt. Items that left the port in 600 ticks,
  and the port's `belt_neighbours.outputs` (same at both tiers except the loader):

  | in front of the port | items leaked | `belt_neighbours.outputs` |
  | --- | --- | --- |
  | nothing | 0 | none |
  | a plain belt passing perpendicular | **16** (side-loaded onto it) | the belt |
  | a belt pointing at the port (head-on) | 0 | none |
  | the next block's input port, its back to this port | **32** (port to port, past the network) | that linked belt |
  | the next block's input port, its side to this port | 0 | none |
  | the next block's output port, its side to this port | 0 | none |
  | an underground entrance | **32** | the underground |
  | an underground exit facing away | 0 | none |
  | a splitter | **30** | the splitter |
  | a loader into a chest | **410 / 560** | the loader |

  So an output port leaks into anything in front of it that accepts items from that side.
  Every leak shows up in the port's `belt_neighbours.outputs`, and every case without a leak
  has it empty (asserted for each case), so a mod can detect a leak without moving any items.
- **Facing rule** (`belt_port_picks_free_side`): place the port facing each direction in turn
  and keep the first whose `belt_neighbours.outputs` is empty. If none is empty, refuse the
  port.
  - On a block with passing belts on two sides and an underground entrance on the third, the
    rule chose the free fourth side, and 0 items leaked in 600 ticks.
  - A block with an accepting neighbour on all four sides was refused.
  - A belt built later across the chosen side appeared in `belt_neighbours.outputs` at once,
    so the re-check can run in the build event.
- Picking from a belt is slower than from a chest (41 vs 45, 47 vs 60 items/s with three
  bulk inserters, above). The share is still exact; it just caps the block at the inserters'
  belt speed, as on a vanilla belt.
- `proxy_block_shares_tile_with_linked_belt` (from round 1, now asserted): on a tile with a
  proxy and a linked belt, an inserter's default `pickup_target` is the linked belt (both
  inserters at tick 60; 0 items taken from the proxy). The control inserter, never written,
  still had the linked belt after 360 ticks. Writing `LuaEntity::pickup_target` to the proxy
  works, sticks, and survives save and load.
- `drop_target_on_shared_tile`: the drop side defaults the other way. An inserter dropping
  onto a tile with a proxy and an input linked belt drops into the **proxy** (`drop_target`
  is the proxy; 144 items in the proxy target, 0 on the belt after 300 ticks). Writing
  `drop_target` to the linked belt works and sticks (48 / 60 more items on the belt side in
  200 ticks). With the belt port there is no proxy on the tile, so both defaults are the port.
- `pickup_target` and `drop_target` read nil until the inserter's first update.

### F4: inserter input

**Result: works and loses nothing, with either design. A block can take inserter input or give
inserter output, not both.**

- `inserter_puts_onto_belt_port`: an inserter drops onto an input linked belt on the block
  tile (its `drop_target` after the first update), linked to the network. From a finite chest
  of 200 plates, all 200 arrived on the network side. It is one more network input: when the
  network backs up, the port fills and the inserters wait, like at a backed-up belt.
- `inserter_puts_into_proxy` (chest port): 200 of 200 through a proxy and a hidden buffer
  drained by a loader.
- `put_and_take_on_one_proxy_bypass_the_network`: with one proxy and its output buffer, 100 of
  100 plates went from a putting inserter straight to a taking inserter, past the network. The
  same holds for an output belt port: an inserter dropping onto it puts items on the dead end,
  where the taking inserters pick them up. So each block has one role.
- My suggestion: allow inserter input, and refuse "both directions on one block" with a
  message.

### F5: lane balancing ("balance lanes" mode)

**Result: exact with lane splitters. Smallest 1:2 construction: one lane splitter before the
splitter (2 entities).**

`lane_mode_balances_lanes`: 1:2 with only the right lane of the input fed (side-loaded; one
full lane is 22.5 / 30 items/s). Each output's lanes are counted on its last belt tile, which
the test empties every tick. Expected per lane: a quarter of the input, 5.625 / 7.5 items/s.

| construction | out1 left | out1 right | out2 left | out2 right |
| --- | --- | --- | --- | --- |
| splitter only (control) | 0 | 11.250 / 15.000 | 0 | 11.250 / 15.000 |
| lane splitter, then splitter | 5.633 / 7.500 | 5.633 / 7.500 | 5.617 / 7.500 | 5.617 / 7.500 |
| splitter, then a lane splitter on each output | 5.633 / 7.500 | 5.617 / 7.500 | 5.633 / 7.500 | 5.617 / 7.500 |

The express deviations (5.633 vs 5.617) are one item out of about 338 per lane in the
3 600-tick window: the discrete item boundary of the count, not a drift.

The vanilla `lane-splitter` exists in base 2.1.23 but runs at yellow speed (0.03125) and is
`hidden = true`, so it cannot be a visible or player-buildable piece. The spike uses a copy at
the tier speed (`mb-spike-lane-splitter`), and the product needs one hidden lane splitter
prototype per tier.

**Recommended design for N:M (corrected in Task 4 fix round 1): one lane splitter on every
input, N of them.** A lane splitter on every input makes the left and right totals equal
before the keep-lanes network splits them, so both lane networks carry flow.

An earlier version of this section recommended the smaller side, min(N, M). That is wrong
for N > M. Output-side lane splitters split exactly as long as the network is below lane
capacity, which is the only case the 1:2 measurement above covered. Above it they lose
throughput: the keep-lanes network carries each lane separately at most 0.5 belt, so an
output's lane splitter can pass only what that output's lanes bring. With only the left input
lanes fed, 8:3 delivers 3 x 0.5 = 1.5 belts instead of 3.0, and 2:1 delivers 0.5 instead of
1.0. The lane-aware flow model (`flow.solve_lanes` in `scripts/flow.lua`, test
`balance_lanes_keeps_full_throughput_with_one_lane_fed`) shows this. Task 5's lane test
asserts total throughput as well as lane equality.

### Concerns for Plan 2

- **Inserter port and the block-tile interface share one tile.** A block with a non-swappable
  neighbour (F1's block-tile interface) cannot have an inserter port. Refuse one of the two
  with a message.
- **Block roles.** Each block's port is either an output port (taking inserters) or an input
  port (putting inserters) or absent. Inserters in both directions on one block need a rule
  (F4).
- **Finding the inserters of a block (role detection).** `inserter_positions_known_at_build`:
  `LuaEntity::pickup_position` and `LuaEntity::drop_position` are correct the moment an
  inserter is built (inserter and bulk inserter: pickup 1 tile behind, drop 1.2 tiles ahead;
  long-handed: 2 and 2.2), while `pickup_target` / `drop_target` are still nil. So:
  - on `on_built_entity` / `on_robot_built_entity` / `script_raised_built` of an inserter,
    find the block on the tile under its pickup or drop position directly, without waiting a
    tick and without anything stored for a later tick;
  - on building a block, search for inserters within the longest inserter reach of any
    loaded inserter prototype (2 tiles in vanilla) with `find_entities_filtered` filtered by
    type `inserter`, and check their positions;
  - re-check on `on_player_rotated_entity` and `on_player_flipped_entity` (the inserter's
    positions change), on mining or destroying an inserter, on `on_entity_settings_pasted`,
    and on inserter upgrades (a different inserter prototype can have a different reach).
  - `pickup_position` and `drop_position` are writable at runtime (for prototypes with
    `allow_custom_vectors`), and no event fires when another mod writes them. A block's role
    can then go stale until one of the events above re-checks it. Accept that, and state it
    in the mod's documentation.
- **Port facing rule (output port leaks).** An output port pushes items into any accepting
  belt-connectable in front of it: a passing belt (side-loading), the next block's input port
  with its back to it, an underground entrance, a splitter, a loader (measured above). Rule:
  - when placing an output port, try the four directions and keep the first with an empty
    `belt_neighbours.outputs`. With none, refuse the inserter port with a message (the block
    then counts as a block without inserters);
  - an input port has the matching risk from behind (it accepts items from a belt-connectable
    whose front faces its back). Choose its direction the same way, with
    `belt_neighbours.inputs` empty. A plain belt pointing into the block is an input and
    becomes an F1 edge, so in practice only non-swappable entities matter, and a block with
    those already uses its tile for the block-tile interface;
  - re-check a block's port whenever a belt-connectable entity is built, mined, rotated,
    flipped, upgraded or destroyed on one of the block's four neighbour tiles. Also re-check
    when F1 swaps a neighbour tile into an edge or back, and when a neighbouring block's port
    changes. If the port's side is no longer free, move the port to a free side (carrying its
    items over, no loss) or refuse it;
  - two adjacent blocks: an output port must not face the back of the other block's input
    port. The rule above covers this (it appears in `belt_neighbours.outputs`), and so does
    any order of building the two ports, because each placement checks the other.
- **Player access to the block.** With the belt port the block is not a container, so it has
  no inventory GUI, and opening it can show the lane-toggle GUI the spec suggests. With a
  chest port, the proxy would show the buffer's inventory when opened, and a player could take
  items out or put items in by hand, past the network (like the F4 bypass);
  `LuaEntity::operable = false` would block that, but then the lane toggle needs another way
  in. Another reason to prefer the belt port.
- **Port contents.** Items wait on the port belt (a few per lane) when nobody takes them.
  Rebuilds and removal must move them (no loss).
- **Port visuals.** The port is a linked belt under the block sprite. Items on it may show
  through, depending on render layers. Plan 2 graphics should check that.
- **Mixed items.** Strictly alternating items on one lane are split by type by any splitter
  (vanilla included). Task 5's `mixed_items_keep_lanes` and Review Focus 3 should state what
  they expect for that case.
- **Not measured here:** an N:M network with an inserter output, long-handed and filter
  inserters on a belt port, an input port next to non-edge neighbours (only edges were
  measured for it), and modded belt-connectables in front of a port. The facing rule handles
  modded ones through `belt_neighbours` without knowing their type.

## F6: save and load with items inside a placed network (Task 5)

**Result: nothing lost, links and hidden flag kept, flow continues.** FactorioTest cannot reload
a save, so this runs as a scripted MCP check through the remote interface `mb-test`
(`tests/game/remote.lua`, loaded only with `factorio-test`). Full log:
`feasibility/f6-save-load.txt`.

- A 3:5 placed by `builder.place` (138 hidden entities) with 3 finite sources of 1 000 plates.
- Saved twice, each time with `game.server_save`, `server_stop` and `server_start` from the save:
  once while flowing (tick 918: 586 items in the network, 1 208 delivered) and once with every
  output blocked (tick 1818: 243 in the network, 200 on the visible side, 2 557 delivered).
- After each load: identical counts per part (sources, visible, network, per output), all 8
  links back to nauvis intact, the surface still hidden for the player force.
- After the first load, flow continued (2 557 delivered 600 ticks later). After the second, the
  outputs were released and all 3 000 plates arrived: 0 left in the network, nothing circulating
  in the loops (Review Focus 1 and 4).

## F7: hidden entity counts and engine cost (Task 5)

**Hidden entities per network** (`builder.place`; every edge is one linked-belt pair, the
network's inputs and outputs are one half each):

| ratio | splitters | lane splitters | linked belts | total | with balance lanes |
| --- | --- | --- | --- | --- | --- |
| 1:1 | 0 | 0 | 2 | 2 | 3 |
| 2:3 | 8 | 0 | 31 | 39 | 45 |
| 2:4 | 7 | 0 | 26 | 33 | 39 |
| 3:5 | 28 | 0 | 110 | 138 | 147 |
| 3:6 | 27 | 0 | 105 | 132 | 141 |
| 8:3 | 24 | 0 | 91 | 115 | 139 |
| 1:5 | 23 | 0 | 88 | 111 | 114 |
| 5:1 | 23 | 0 | 88 | 111 | 126 |
| 16:16 | 64 | 0 | 256 | 320 | 368 |

**Engine cost** (MCP `benchmark_run`, vanilla, 5 runs of 1 000 ticks, 100 warm-up ticks dropped,
median ms per tick; instance `mb-t5b` with `modular-balancer` and `factorio-test`; saves built
with `remote.call("mb-test", "bench_hidden" | "bench_vanilla", 50)` and run 1 200 ticks before
saving, so everything is saturated):

| save | content | wholeUpdate | transportLinesUpdate | entityUpdate |
| --- | --- | --- | --- | --- |
| empty | the same fresh map, nothing built | 0.187 | 0.071 | 0.002 |
| hidden | 50 x 8:3 on `mb-hidden` (1 200 splitters, 4 550 linked belts), each with 8 endless sources and 3 sinks on nauvis; 150 belts of output | 0.528 | 0.137 | 0.221 |
| vanilla | 50 x 24 = 1 200 vanilla express splitters on nauvis, 8 rows of 3 splitters in series per copy, 400 sources and 400 sinks; 400 belts of output | 0.671 | 0.142 | 0.369 |

- **Do not compare the two saves directly.** They differ in throughput and in topology:
  - the vanilla save moves about 2.7 times as many items (400 rows at 45/s, against
    50 x 135/s);
  - it has 2.7 times as many sinks;
  - its splitters have a dead-end output, so once filled they act like straight belts.

  So no ratio between the `wholeUpdate` columns (or the deltas below) means anything about
  hidden networks against vanilla balancers.
- What the numbers do show, per save:
  - `entityUpdate` is mostly harness: loaders 0.076 (hidden) and 0.154 (vanilla), infinity
    containers 0.087 and 0.161.
  - About 0.055 ms of `entityUpdate` remains in both saves after those are subtracted. That
    is probably the splitters' own entity update (1 200 splitters in each save), so the
    network's cost is that remainder plus its share of `transportLinesUpdate`.
  - `transportLinesUpdate` rises 0.066 ms over the empty map for 50 saturated 8:3 networks
    plus their harness belts.
- Numbers only. The gate is Plan 3's comparison with Better Belt Balancer, which should use a
  real vanilla 8:3 balancer blueprint as the vanilla reference.

## F8: equal redistribution option, recirculation (Task 5, experimental)

**Not the Plan 1 design.** Ruling 6: in Plan 1 a slow output (belt or inserter port) behaves like
a vanilla splitter output. Its unused share goes to its last-stage sibling, exactly as
`flow.solve` predicts. `inserter_share_*` asserts that match, measured throttled 2:3: belts
22.500 / 42.283 / 22.500, port 2.717, flow model identical. The user chose the recirculation
design below for every output in Plan 2. Prototype: harness option `recirc`
(`tests/game/harness.lua`). Tests: `tests/game/recirculation.lua`. Offline model check: a
fixed point over `flow.solve` (see below).

**Design.** For a ratio n:m with M outputs (belt outputs plus inserter ports):

- Build the network as (n + M):M.
- Network output j goes to a hidden splitter with `splitter_output_priority = "left"`. The
  priority side is the real output j: the edge's linked belt, or the port.
- The other side is linked back into network input n + j.

So whatever output j does not take re-enters the network and is spread over all outputs again.
In steady state each output takes min(its demand, x), and x is the same for every output that
is not limited ("water filling").

**Measured in game** (express, 3 600 ticks after a 3 000-tick warm-up, items/s; from the run
at `f90270a`, full log in `feasibility/t5-results-vanilla.txt`; refreshed in Plan 2 Task 2,
final review M6. The prototype suite `tests/game/recirculation.lua` was removed in Plan 2 Task 2:
the v2 generator recirculates by itself, see F9):

| case | 2:3 | 3:5 |
| --- | --- | --- |
| all outputs free | 30.000 x3 = 90.000 (plain network: 90) | 27.000 26.967 26.983 27.000 27.000 = 134.950 (135) |
| input 1 at a third | 20.000 x3 = 60.000 (supply 60) | 21.000 x3, 21.017, 21.000 = 105.017 (105) |
| output 1 slow (15) | 15.000; others 37.500 37.500 (expected 37.5) | 15.000; others 30.000 x4 (30) |
| inserter port slow (2.733) | belts 29.100 x3 (expected 29.089) | belts 26.450 x5 (26.453) |
| only outputs 1, 2 open | 45.000 / 45.000; draw 45.000 / 45.000 | 45.000 / 45.000; draw 45.000 / 22.500 / 22.483 |

- No loss or duplication: every F8 test checks at its end that sources + belts + network +
  recirculation entities + sinks + port equal the stock. All passed. All F8 tests pass in
  vanilla and Space Age (whole suite at `f90270a`: 47/47 vanilla, 48/48 Space Age).
- Throughput with all outputs free is unchanged against the plain network, within 0.02 %.
- **It takes longer to settle.** From an empty rig, the total reaches steady state after about
  2 400-3 000 ticks, against 600 for the plain network. Per 600-tick window, 2:3 with a slow
  belt: 25.5, 74.3, 85.3, 89.1, 89.8, 90.0. With the 600-tick warm-up of the other suites it
  measured 1-4 % low (for example the 3:5 slow port at 129.7 instead of 135).

**Flow model check** (offline, `lua52`; a fixed point that alternates `flow.solve` on the
(n + M):M network with loop supplies = max(0, x_j − d_j); 360 random cases over every ratio
with n + m ≤ 16):

- Any input mix with outputs free: outputs equal, total min(S, m). **0 failures.**
- One slow output (random demand): the others equal at min(1, (n − d)/(m − 1)). **0 failures.**
- Throughput unlimited (random fed inputs, random open outputs, the rest demand 0): open
  outputs total min(fed, open). **0 failures.**
  - In 98 of these cases the overflow is larger than its loop input accepts, so the priority
    splitter backs up. The model ignores that back-up, so in those cases it is only
    approximate.
  - The engine case "3:5, only 2 outputs open" (which backs up like this) still delivered 2
    full belts.
- **Input balance under backpressure is lost: 144 failures.** When the open outputs cannot take
  everything, the loop inputs compete with the real inputs, and the real inputs are no longer
  drawn equally.
  - Flow model, 3:5 with 2 outputs open: 45 / 33.75 / 33.75.
  - Engine: **45.000 / 22.500 / 22.500**.
  - The model's simplest case: 2:1 (a 3:1 network with an empty loop input) also draws
    unequally.
  - The plain network draws equally in that regime (`inputs_drawn_equally_*`).
  - Plan 2 must decide whether this is acceptable or add a fix.
  - **Resolved in Plan 2 Task 1:** the generator v2 puts an exact N:N front core before the
    recirculating (N+M):M core, so every input is drawn equally with any subset of outputs open
    (offline `recirc_f8_case_draws_equally`; in game F9 "equal draw").

**Size cost** (splitters / hidden entities; recirculation = the (n + M):M network + M priority
splitters + 4 entities per output):

| ratio | plain | recirculation |
| --- | --- | --- |
| 1:1 | 0 / 2 | 2 / 8 |
| 2:3 | 8 / 39 | 31 / 150 |
| 2:4 (2:3 + port) | 7 / 33 | 27 / 129 |
| 3:5 | 28 / 138 | 40 / 192 |
| 3:6 (3:5 + port) | 27 / 132 | 81 / 396 |
| 4:4 | 8 / 40 | 24 / 112 |
| 5:1 | 23 / 111 | 23 / 109 |
| 1:5 | 23 / 111 | 41 / 199 |
| 8:3 | 24 / 115 | 66 / 319 |
| 8:8 | 24 / 120 | 60 / 284 |

In Plan 1 the (n + M):M network must fit `network.MAX_SIDE` = 16 inputs, so with recirculation
the largest ratios shrink to n + M ≤ 16 (8:8 fits, 9:8 and 16:16 do not). The spec's Update
2026-10-24 (2) already removes MAX_SIDE in Plan 2 (any size, exhaustive offline checks up to
16:16), so the limit itself goes away. What stays is the cost: the recirculation network is
(n + M):M. Merging several overflows into fewer loop inputs would make it smaller, but that
changes when the overflow backs up and needs its own measurement.

## F9: builder v2 in the engine (Plan 2 Task 2)

Logs: `feasibility/p2-t2-results-vanilla.txt` (53/53) and `p2-t2-results-space-age.txt`
(55/55). Express tier unless noted. All rates are items/s over 3 600 ticks.

**Vanilla output priority behaves like the model's priority node, per lane.** A single
priority splitter is fed a full belt (iron on the left lane, copper on the right). Port 1 has
priority and its sink is throttled:

| port 1 sink | port 1 iron / copper | port 2 iron / copper | `flow.solve` port 1 / port 2 |
| --- | --- | --- | --- |
| half speed (22.5) | 11.250 / 11.250 | 11.250 / 11.250 | 22.5 / 22.5 |
| basic (15) | 7.500 / 7.500 | 15.000 / 15.000 | 15 / 30 |

Each lane is prioritized on its own: port 1 takes what it can from each lane, and port 2 gets
the rest of that lane.

**v2 networks (recirculation on) are exact on every Plan 1 ratio.**
- 2:3, 3:5, 8:3, 1:5, 5:1 and 1:1 give equal outputs, equal draw and full throughput. For
  example 3:5: outputs 26.983-27.000; draw 37.500-37.517 against 5 x 22.5 delivered.
- Unequal inputs, mixed lanes, lane balance and the belt port all hold.
- `recirc_slow_belt`: 2:3 gives 15.000 / 37.500 / 37.500; 3:5 gives 15.000 / 30.000 x4.
- Throttled `inserter_share` 2:3: belts 29.083 / 29.100 / 29.083, port 2.717; `flow.solve`
  gives 29.094 x3.

**Settling.** v2 3:5 with one slow output, total per 600-tick window from an empty rig:

  33.4, 125.8, 134.6, 134.8, 135.2, ...

It is within 1 % of 135 from the third window, about 1 800 ticks. The F8 prototype needed
2 400-3 000. The suites still warm up for 3 000 ticks.

**Backpressure reaches the full state** (final review M2). In a 3:5 with every output blocked,
no input draws anything in the last 120 of 2 400 blocked ticks, and the network then holds
1 528 items. After the release the outputs run at 29.5 each, flushing above the 27 steady
state, and are equal.

**Dead ends are closed by a filter.**
- A plain splitter with one unconnected output gets output priority on the dead end, with
  `splitter_filter` set to `mb-hidden-never`, a hidden item that never exists. So no item
  enters the dead end.
- Without the filter (first try, priority on the live side only), a 3:1 network kept 12 items
  on its dead ends after the shrink drain: they fill whenever the live output backs up, and
  never leave.
- With the filter, after the shrink every item came out (0 left in the network).

**A loader only serves a container with the `player-creation` flag.** Measured on nauvis with a
test loader and steel-chest copies:
- `loader_container` stays nil when the chest's flags are the hidden set or only
  `placeable-neutral`;
- it is set with the vanilla flags, or with `player-creation` plus `not-selectable-in-game`;
- `hidden`, `minable = nil`, `allow_copy_paste = false`, `inventory_size = 1` and
  `quality_affects_inventory_size = false` make no difference.

`mb-hidden-buffer` therefore keeps `player-creation`.

**Rebuild and carry-over** (`builder.rebuild`). The new network is placed, the old network's
items are copied onto its belts (not onto closed dead ends), the rest go into its buffer chest
(grown with `set_inventory_size_override`), and then the old network is destroyed.

| case | items in the network | after the rebuild | buffer |
| --- | --- | --- | --- |
| backed-up 3:5 -> 3:5 | 1 528 | 1 528 | 28 |
| backed-up 3:5 -> 3:1 (shrink) | 1 528 | 1 528 | 1 460 (15 slots) |
| backed-up 3:1 -> 3:8 (grow) | 110 | 110 | 0 |
| 3:5 with 680 plates -> 1:1 | 680 | 680, normal and uncommon kept (Space Age) | 664 |

- After the shrink, with feeding stopped, the single output delivered 1 688 items in 6 000
  ticks and the network was empty.
- While the buffer drains, the output still runs at 45.000. The buffer shares input 1 through
  a merge splitter: input 1 is drawn at up to half a belt until the buffer is empty.
- A rebuild that fails to place (test hook) leaves the old network untouched.

**Item stacks are carried, not recreated** (Task 2 review I1, fix round 1). `rebuild` reads
the old network's stacks with `get_detailed_contents` (belts) and slot by slot (buffer), and
inserts the `LuaItemStack`s themselves.
- 20 blueprints (one entity each, labelled) and a modular armor with a solar panel in its grid
  go from a 3:5 to a 1:1 (16 stacks onto the new belts, 5 into the buffer). Every blueprint
  keeps its label and entity, and the armor keeps its equipment.
- 340 yumako with spoil fractions 0.2-0.8 (Space Age): total spoilage 169.4000 before and
  169.4164 after. Items on the new belts keep their own fraction (the freshest is still 0.2000);
  stacks merged in the buffer average theirs, as in any chest.
- No item kind was refused by a belt in these tests. A stack refused at a free belt position
  goes into the buffer as a stack.
- A rebuild needing more buffer slots than allowed (test: `builder.max_buffer_slots = 1`)
  returns `nil, "too-many-items"`. The old network's contents and the region count are
  unchanged.
- `mb-hidden-never` (cheat-only) is left out of `contents` and dropped by a rebuild.
- Fix round 2:
  - **Belt copies are explicit.** Belt copies use `insert_at(pos, stack, 1)`, and a copy that
    takes more items than the stack has left raises an error (the rebuild then fails cleanly).
  - **Second rebuild with a full buffer.** A backed-up 3:5 shrunk to 3:1 (1 460 in the buffer)
    and at once rebuilt as 3:2 still holds exactly 1 528 plates; 1 256 were left in the buffer,
    after splitting its 100-plate stacks onto the new belts.
  - **Stacks with per-item state stay whole.** Stacks of several items with per-item state go
    into the buffer whole (ammo, tools and repair packs, damaged items): copying one item would
    copy the top item's partial state. The remainder of a split plain stack is a `set_stack`
    copy with its count lowered, so it keeps every field.
  - **Measured.** 10 magazines (top at 3 of 10 rounds), 5 repair packs (top at half durability)
    and 50 plates in the old buffer give 93 rounds, durability 1 350 and 50 plates after the
    rebuild, with the plates split onto belts.

**Rebuild cost at 64:64** (recorded; `helpers.create_profiler`).
- An empty `place` of the 4 677-entity network takes 54-57 ms.
- A rebuild of the same network with every hidden linked-belt position full (14 856 plates, all
  carried onto the new belts) takes 217-221 ms.
- So carrying costs about 160 ms, about 11 µs per item (two `get_item_count` calls and one
  `insert_at` per item), on top of `network.build`. The UPS budget and Task 4 rebuild policy
  should account for it.

**Atomic placement.** A failure while creating entity 1, 2, 40 or 120 of a 3:5 leaves no
entity on the hidden surface, and its region is released.

**Tier speeds come from the final prototypes** (final review M3). The hidden prototypes are
built in `data-final-fixes.lua`. With the test mod `tests/mods/mb-test-speed` (express belt
26/256 in its data-final-fixes), every hidden express entity had speed 0.1015625 (MCP check,
`feasibility/p2-t2-speed-mod.txt`).

**Lane splitters per tier** (final review M8). A 1:1 with balance lanes, left lane only:

| tier | left / right lane |
| --- | --- |
| basic | 3.750 / 3.750 |
| fast | 7.500 / 7.500 |
| express | 11.250 / 11.250 |
| turbo | 15.000 / 15.000 |

Each is exactly half a belt of its tier.

## F10: lifecycle in the engine (Plan 2 Task 5)

Suite `tests/game/lifecycle.lua` (22 tests after the final fix round, both presets; full runs `feasibility/p2-t5-results-vanilla.txt` 181/181, `p2-t5-results-space-age.txt` 183/183, spikes on); MCP checks in
`feasibility/p2-t5-mcp-checks.txt`. fdev test is headless and has no player, so the player-only
events (on_player_setup_blueprint, on_undo_applied, rotate and flip) are driven by calling the
mod's handlers with the event fields they read, after doing to the world what the game would do.

**Blueprints.** `LuaItemCommon::create_blueprint` over a running balancer records each edge as
itself (`mb-edge-in-express-transport-belt`, `type = "input"`), as F1 found. After the rewrite
(`lifecycle.clean_blueprint`, run from on_player_setup_blueprint, which copy and cut raise too)
a 2:3 holds 2 blocks and 15 plain belts and nothing else of the mod; the block-tile linked belt is
`not-blueprintable`; a wired input belt (Ruling 7) keeps its wire. Pasted (build_blueprint with
raise_built) and revived, it is a 2:3 again and its outputs measure 29.967 / 30.000 / 30.000. A blueprint made
without the rewrite pastes too: its edge ghosts become belt ghosts as they are placed.
- The harness loaders and chests (`minable = nil`) are not blueprinted; the tests rebuild them.

**Edges cannot follow the upgrade planner.** `order_upgrade` on an edge with another edge
prototype as target (same `fast_replaceable_group`, `placeable_by` the new belt) returns false
(prototype, name or `{name, quality}`). Design instead: on on_marked_for_upgrade of a transport
belt, an edge of the same belt that it feeds or is fed by is swapped back to its belt and that
belt gets the same order (player kept for the undo queue). A belt marked for upgrade is not a
port, so the order survives; once robots (here `apply_upgrade`, which raises
script_raised_destroy/_built) upgrade it, it becomes an edge of the new belt. Items kept.

**Block upgrades.** `order_upgrade` + `apply_upgrade` of a basic block to fast: the fast block is
already in a fast group when `apply_upgrade` returns (the old block is gone before the new one's
build event: no overlap refusal, Task 3 note). A fast-replace `create_entity` of an express block
over it behaves the same. The old network's items reach the new tier's network through the
retire-by-tile rule (`scripts/balancer.lua`); measured equal before and after.

**Removing a block.** With the network's last block mined by a construction robot, the network's
items go into the robot's logistic network (a storage chest got all 26; nothing on the ground).
A player's inventory gets them the same way (not testable headless). A block destroyed with no
miner still spills them at its tile.
- Undo of that removal rebuilds the block from its ghost on that tile. The spilled items lie on
  the tile, and a script `revive` without `overflow` deletes the item-on-ground entities it
  collides with (measured: 26 of 600 plates gone). The test passes an overflow inventory. A
  player or robot build moves colliding items rather than deleting them, but this was not measured.

**Edges and rotation.** A connected edge can be rotated (`rotate` returns true and keeps its
link). Turned round it becomes the other role, turned sideways a plain belt again.

**Deconstruction marks** survive the swaps in both directions (`order_deconstruction` on the new
entity).

**The hidden surface deleted.** `delete_surface` returns true and the surface is gone on the next
tick; on_pre_surface_deleted comes first, so the networks' items are spilled at their blocks, and
the next flush places every network on a new `mb-hidden`, which can get the same surface index
as the old one.

**Space Age removed (Review Focus 5).** With the turbo block and hidden turbo prototypes defined
without Space Age, a save with a backed-up turbo 1:1 (1 000 plates in all, 26 in the network)
loads in vanilla: on_configuration_changed replaces both turbo blocks by express blocks, the next
tick carries the turbo network's items into a new express network, total 1 000.
- Edges of turbo belts, like the player's turbo belts, are deleted by the game with their items
  (as vanilla deletes turbo belts).

**Speed changed by a mod.** Existing hidden entities and edges follow their changed prototypes
after a load with `mb-test-speed` added (express 0.1015625 everywhere, items kept). A
configuration change refreshes every group without rebuilding an unchanged one.

**Fix round 1 (review of Task 5).**
- *Pending work rule (I1).* The flush handler is armed whenever `balancer.pending` is true (dirty
  groups or loose edges) and `on_load` re-arms from the same rule. MCP: a lone loose edge saved in
  its build tick is swapped back on the first tick after loading (`p2-t5-mcp-checks.txt` 5).
- *Spills never land on the group's tiles (I2).* A destroyed group's network (and any sink
  overflow, and the hidden-surface drop) is spilled stack by stack on the nearest free tile
  outside every tile the group occupied, marked for deconstruction by the group's force.
  `destroyed_group_rebuilt_by_robots_keeps_items`: two backed-up blocks `die()` with ghosts on
  death; 26 plates spilled, none on a block tile, all marked; robots rebuilt both blocks from
  their death ghosts and carried all 26 into the storage chest; 600 of 600 (robot cargo bonus 10 in
  the test; with cargo 1 the pick-up of one 11-plate stack took over 4 000 ticks). The undo test
  now revives the block without an `overflow` inventory and loses nothing.
- *Space platform sink:* a platform's hub gets the items (`platform_sink_gets_items`, Space Age).
- *Leftover orphan blocks:* without Space Age, a turbo block or ghost placed later becomes an
  express block or ghost at once.
- *Undo of an upgrade:* `upgraded-entity` on an edge's tile swaps the edge back and orders the
  original belt. The belt ghost that replaces an edge ghost is created for the player who placed
  it (so it should join that player's undo item; not verifiable headless).
- *Surface clear:* `hidden_surface_cleared` (LuaSurface::clear): spilled first, placed again,
  items kept, runs.
- *Blueprint sources:* event.record (or a book record's selected record), event.stack (or a
  book's active blueprint), blueprint_to_setup and the cursor (or its book's active blueprint) are
  all cleaned; `set_blueprint_entities(entities, false)` keeps positions. A real Ctrl+C / book /
  library session is still not run (no player headless).

**Final fix round (Plan 2 final review).**
- *No inventory is sized by item count (I1).* `builder.take` fills script inventories of at most
  `builder.max_take_slots` (65 535, the uint16 limit of `create_inventory`) slots, merging as it
  inserts and opening a new inventory only when one is full even merged. `carry_into` caps the
  buffer at `builder.max_buffer_slots` and lets the inserts merge, refusing only when the merged
  items do not fit. Tests: `take_uses_bounded_inventories` (cap 1, iron and copper: at least two
  inventories, every plate kept, none on the block tile) and `carry_merges_into_a_capped_buffer`
  (a 1:2 shrunk to 1:1 with more single belt items to buffer than its 3-slot cap: rebuilt, all
  600 plates kept).
- *Belts of another force* next to a block are never swapped or linked; one pointing into or away
  from a block is refused ("other-force").
- *Block-tile port items* of a removed group go to the miner or are spilled off the group's tiles,
  marked for its robots (`block_tile_port_items_spilled_off_the_tile`).
- *A cloned block-tile linked belt* is loose until a port claims it; else it is removed and its
  items go to the network of the group on its tile, or are spilled
  (`cloned_block_tile_belt_cleaned_up`).

**Save mid-rebuild.** A save made in the tick the blocks and belts were built (groups dirty, no
network yet) builds the balancer on the first tick after loading (on_load re-arms the flush),
items kept (64 of 64).

## F11: real-player checks (Plan 3 Task 5)

MCP instance `mb3-t5a` (vanilla, `dev_mods` = this worktree, `portal_mods` = factorio-test so the
`mb-test` interface exists), a GUI client joined with `gui_connect` (player 1, a character made
indestructible on a refined-concrete test field). The player was driven from `exec_lua`:
`build_from_cursor` with the item in `cursor_stack`, `mine_entity`, `update_selected_entity`,
`set_controller`, `player.opened`, `add_to_clipboard` + `activate_paste`. Keys and clicks cannot
be sent to the client, so the linked custom inputs and the GUI clicks were raised through the new
`mb-test` functions `input`, `click` and `setup_blueprint`, which call the mod's handlers with the
event a key press, click or Ctrl+C raises for the real player (its real selection, cursor, reach,
controller and permission group). Rig: an express 2:3 (3 blocks, two inputs fed by loaders from
2 000-plate chests, three outputs into chests), all blocks and belts built by the player.
Invariant checked after every step: iron plates on nauvis (belts, edges, loaders, chests, ground,
the player's inventory) plus the hidden surface.

Harness notes:
- `build_from_cursor` and `can_build_from_cursor` refuse everything (even an iron chest on empty
  concrete) while the server is tick-paused, which is how fdev holds it between calls. Each build
  call unpauses (`game.tick_paused = false`) and pauses again in the same command.
- Lua globals defined from the console are not in the level state of a client that joins later:
  the first call of such a helper after a reconnect ran on the server only and desynced the client
  (client log: heuristic CRC failure at the first `mbbuild` call after the rejoin; a call with
  locals only, just before it, did not). With the helpers defined again after the rejoin, the same
  steps ran without a desync. A harness artefact, not the mod's.
- `set_controller` raises neither `on_player_controller_changed` nor `on_player_changed_position`
  (watched from a level-script handler), so leaving remote view by script is not the same as a
  real player leaving it.

| check | result |
| --- | --- |
| drag over an edge, same belt and direction (the real `on_pre_build`) | pass: swapped back in the build call, an edge again after the next flush; total kept |
| belt of another direction over an input edge | pass: the game rotates the plain belt, the balancer becomes 1:3; turned back, 2:3 |
| belt of another tier (fast over express) | pass: a fast edge, 2:3, total kept |
| underground belt on an output edge, splitter over two output edges | pass: both become block-tile ports (F3), 2:3, total kept (`f11-splitter-underground-on-edges.jpg`) |
| build beyond the build distance | `build_from_cursor` builds at 19.5 tiles (reach 10); swapped back, total kept |
| **remote view build (old code)** | **fail: a real fast belt replaced the edge (not a ghost, even with the character 50 tiles away); 2 plates lost** |
| remote view build (fixed) | pass: 4 plates on the edge, all kept |
| **forced / super-forced build over an edge (old code)** | **fail (no loss): a belt ghost, and the edge marked for deconstruction** |
| forced / super-forced build (fixed) | pass: as on a plain belt, another tier gets an upgrade order, another direction rotates in place |
| blueprint of a different belt over an edge (forced) | limit, documented: ghost and deconstruction mark on the edge (robots replace it, items kept); a blueprint of the balancer over itself changes nothing |
| copy (Ctrl+C) and paste, real cursor | pass: `on_player_setup_blueprint` on the cursor blueprint gives 3 tagged blocks and 7 plain belts; pasted ghosts carry the tags; the player building the blocks over the ghosts gets a group with the blueprint's settings |
| clipboard paste (`add_to_clipboard`, `activate_paste`) | pass: ghosts with the tags |
| blueprint book | not drivable: `can_build_from_cursor` is false for a book in the cursor at every position tried (the book's active blueprint is cleaned, F10 tests) |
| blueprint library, cut | not drivable: no API adds a library record; cut is copy plus deconstruction marks |
| undo/redo after swaps | not drivable: `LuaUndoRedoStack` has no apply method. The stack after mining shows one `removed-entity` action per block and no tags, so undoing the removal of a whole balancer gives the default settings (README) |
| mining the last block of a full balancer, inventory nearly full | pass: 100 plates to the 1 free slot, 160 spilled in 2 stacks off the block tiles, marked for deconstruction; total 3 993 of 3 993 (`f11-mined-full-balancer-spill.jpg`) |
| flying-text refusals | pass: "the last belt tile into a block must be straight" for the player who built it (`f11-flying-text-refusal.jpg`); a belt on a block tile is handed back |
| settings window | pass: opens on the selected block in reach with an empty cursor, title bar with close button (`f11-settings-window.jpg`); `player.opened` is the frame |
| checkbox | pass: lanes on, next flush rebuilt with lane splitters, total kept |
| close button, Esc (`player.opened = nil`) | pass: frame gone, state cleared |
| walk out of reach (teleport) | pass: `on_player_changed_position` closed it at once |
| block mined while open | pass: closed at the next flush |
| remote view | pass: opens from remote view with the character 45 tiles away (`f11-settings-remote-view.jpg`) |
| leaving remote view by script, out of reach | the frame stays (no event, above) and `player.opened` was nil; fixed: the next check (move, flush) opens it again as `player.opened` so E/Esc work; a real exit raises `on_player_controller_changed`, which closes it (not verifiable here) |
| permission group without open-gui | pass: refused; back in Default, opens |
| copy, change the source, paste (M4) | pass: the destination gets the source's settings as they are at paste time |
| `LuaEntity::copy_settings(source, player)` between blocks | raises `on_entity_settings_pasted` (the destination took the settings); a block is accepted as `player.entity_copy_source`, so vanilla Shift-click paste most likely reaches the mod too (both paths give the same result) |
| player leaves (client closed) | pass: frame destroyed, state cleared |

Fixes from these checks: `lifecycle.pre_build` now swaps edges back for every build from an item
cursor, in any build mode and in remote view (test `pre_build_guards` updated), and an open frame
that lost `player.opened` gets it back.

## Concerns for Plan 2 from Task 5 (parked review minors)

Status after Plan 2 Task 2: the first item is fixed (`builder.place` is all or nothing), and
`Placed` now records origin, size, tier and force. The allocator and cross-force items are still
open.

- **A failed `builder.place` leaves a half-built network.** If a `create_entity` fails, the
  builder asserts after earlier entities already exist, and they are never destroyed. Review
  Focus 5 says "never a half-built network". Plan 2 must, for example, wrap the build in
  `pcall`, destroy `placed.entities` on failure and then rethrow, or check the whole rectangle
  first.
- **The region allocator never splits or merges free regions.** `surface.reserve` reuses a
  released region whole, first fit, so a 10x10 request can take a released 256x256 region. That
  is correct and has no overlap, but fragmentation grows with churn, and Plan 2 rebuilds
  networks often.
  - `Placed` does not record its `origin` or tier, so the caller must keep both to release and
    rebuild. Consider storing them in `placed`.
- **The `force` argument of `builder.place` is untested across forces.** Plan 2 should check
  that a hidden linked belt of the owner's force links to the visible edge belts, and what
  happens when a block changes force.
