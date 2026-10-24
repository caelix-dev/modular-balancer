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
