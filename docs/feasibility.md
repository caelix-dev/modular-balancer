# Feasibility findings

Measured in Factorio 2.1.23 with fdev (`fdev test`, MCP `server_start` / `exec_lua` /
`screenshot`).

Spike code lives in `spikes/`. It loads only when the hidden startup setting `mb-spikes` is on.
That setting is forced on when two things hold: the git-ignored file `spikes/local-enable.lua`
exists (it returns `true`, or `{ variant = "<name>" }` to pick a prototype variant), and the
`factorio-test` mod is enabled. Otherwise it is forced off. See `settings.lua`.

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

**Recommended design for N:M:** put the lane splitters on whichever side has fewer belts, so
min(N, M) of them. Either placement is exact:

- A lane splitter on every input makes the left and right totals equal before the keep-lanes
  network splits them.
- A lane splitter on every output averages that output's left and right shares, which the
  keep-lanes network makes equal across outputs.

The choice only changes the entity count. Both placements were measured equal, in the 1:2
case only; behaviour under partial backpressure was not compared. The plan owner assigns the
N:M check to Task 5.

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
