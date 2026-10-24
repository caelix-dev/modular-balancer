# Feasibility findings

Measured in Factorio 2.1.23 with fdev (`fdev test`, MCP `server_start` / `exec_lua` /
`screenshot`). Spike code: `spikes/`, loaded only with the hidden startup setting `mb-spikes`,
which is forced on by the git-ignored file `spikes/local-enable.lua` (`return true`) and forced
off without it. Run with `fdev test modular-balancer [--preset space-age]`; results are logged
with the prefix `MB-SPIKE` in the test instance's `factorio-current.log`.

## F1: several belts per 1x1 block (spike S1)

**Result: possible, but not on the block's own tile.** 2.1 allows exactly one belt-connectable
entity per tile, enforced at the prototype stage and at runtime. A block takes a belt on each
free side by putting the interface on the *player's belt tile* next to the block: that belt
tile is swapped for an "edge" linked belt of the same belt tier, linked into the hidden
network. Measured: input on one side and output on another at full belt speed, and two in plus
two out on all four sides at once, with no throughput loss (45/45 items/s express, 60/60
turbo).

### Why the block tile cannot hold more than one interface (measured)

Prototype stage (the game refuses to load; errors from `factorio-current.log`):

| tried | error |
| --- | --- |
| linked belt per side, each on its own custom collision layer | `entity prototype "mb-spike-lb-e" (linked-belt) collision_mask must collide with entity prototype "transport-belt" (transport-belt) collision_mask.` |
| linked belt per side, each on a *different* layer of the vanilla belt mask (`floor`, `meltable`, `transport_belt`, `water_tile`), so each collides with transport belts but not with each other | `entity prototype "mb-spike-lb-n" (linked-belt) collision_mask must collide with entity prototype "mb-spike-lb-e" (linked-belt) collision_mask.` |
| one shared belt mask with `not_colliding_with_itself = true` | `entity prototype "mb-spike-lb-e" (linked-belt) collision_mask must collide with entity prototype "mb-spike-lb-e" (linked-belt) collision_mask.` |

So in 2.1 every belt-connectable prototype must collide with every other one, itself
included. This is the "closed collision behaviour" Better Belt Balancer's 0.2.0 changelog
refers to.

Runtime (FactorioTest, `spikes/multi_belt/test.lua`), on a tile that already holds a linked
belt: `LuaSurface::create_entity` of a second linked belt returns nil, `LuaEntity::clone` onto
the tile returns nil, `LuaEntity::teleport` onto the tile returns false; a loader-1x1 on a
loader tile is refused the same way. Non-belt entities (the block, a linked chest) can share
the tile with one belt-connectable entity.

### Candidates

| | candidate | placeable | belts connect | throughput (items/s) | test |
| --- | --- | --- | --- | --- | --- |
| a | several hidden linked belts on the block tile, disjoint collision layers | no (prototype error, and runtime refuses stacking) | - | - | `spike_stacked_linked_belts_input_and_output_on_one_tile (refused)` |
| b | loader-1x1 per side on the block tile into a shared hidden chest | no (same rule: loaders are belt-connectable) | - | - | `spike_stacked_loaders_input_and_output_on_one_tile (refused)` |
| c | the visible block is itself belt-connectable (linked belt with `allow_side_loading`) | yes | inputs only: back and the two sides feed the network, nothing can leave to the east (a linked belt is one-way; side-loaded inputs fill one lane only) | east belt received 0 items in 600 ticks | `spike_block_as_belt_input_and_output_on_one_tile (no output)` |
| d | from the changelog: 2.1.16 "Fixed a crash when rendering linked belt without structure sprites": a linked belt with no structure draws as a plain belt. No 2.1 entry adds a way to stack belt-connectables. Used by (e) | - | - | - | - |
| e | **edge interface**: the player's belt tile next to the block becomes a linked belt (same tier, mines back to the belt item) linked to the network; the block tile holds no belt entity | yes | yes, each edge has exactly one belt neighbour | 45.00 express / 60.00 turbo, one in one out; four sides (2 in, 2 out): 45.00 + 45.00 / 60.00 + 60.00 | `spike_edge_input_and_output_on_one_tile`, `spike_edge_throughput`, `spike_edge_four_sides` |
| e+ | **hybrid**: the block tile holds one linked belt for a side whose neighbour is not a plain belt (here an underground exit), the other sides are edges | yes | yes; the block-tile linked belt has 1 input, 0 outputs (no cross-talk with the edges) | 45.00 + 45.00 / 60.00 + 60.00 on four sides | `spike_hybrid_four_sides` |

Inserter feed test (infinity chest, burner inserter, west belt): the first item reached the
east belt after 84 ticks (express) / 75 ticks (turbo). Throughput is measured over 1 200 ticks
after a 600-tick warm-up, loader-fed from an infinity chest into a counted steel chest. In
these tests each input edge is linked straight to an output edge (the network is Task 3-5).

Swapping a full belt tile (4 items per lane) for an edge keeps every item, but an edge line is
half a tile long (`line_length` 0.5): 2 + 2 items stay on the edge, the other 2 + 2 must go
onto the linked partner (the network side). Test `spike_edge_swap_keeps_items`: 8 of 8 kept,
0 lost.

Looks (screenshots, express tier, vanilla graphics):

- `feasibility/f1-edge-hatch-four-sides.jpg`: edges with the vanilla linked-belt hatch
  structure on all four sides of a block. Reads as one machine taking four belts.
- `feasibility/f1-edge-plain-four-sides.jpg`, `feasibility/f1-edge-plain-saturated.jpg`:
  edges with no structure sprite. The belt is drawn on the half tile away from the block only,
  leaving a half-tile gap before the block; it needs a structure sprite (hatch or housing lip).
- `feasibility/f1-block-tile-linked-belt.jpg`: the Better Belt Balancer way (one linked belt
  on the block tile, under the block sprite) for comparison: the belt runs into the block.

### Chosen design (F1)

Per block:

- **The visible block**: a non-belt-connectable building (here `simple-entity-with-owner`
  with mask `item`, `player`, `is_object`), so it shares its tile with at most one hidden
  linked belt and any number of non-belt entities (the Task 3 proxy chest).
- **Edge interfaces, one per attached belt** (the default for every side). When a plain
  `transport-belt` points into a block (input) or starts next to it pointing away (output),
  its tile is swapped for an edge linked belt: `linked_belt_type` `input` (or `output`), the
  same direction as the belt it replaces, the same speed as that belt, `minable.result` and
  `placeable_by` the replaced belt's item (so mining gives the belt back and nothing is
  duplicated). The edge is linked to the network's input or output linked belt with
  `connect_linked_belts`. Items on the swapped tile are moved onto the edge and, for what does
  not fit (half tile), onto the linked partner. Visually: the player's belt runs into a
  hatch at the block's face (structure sprite; Plan 2 graphics may replace the hatch).
- **One block-tile interface** (optional) for a side whose neighbour cannot be swapped
  (underground belt exit or entrance, splitter, another mod's belt-connectable): a hidden
  linked belt on the block tile facing that side. At most one per block; a second
  non-swappable neighbour on the same block is refused with a message.

Up to four belts per block (all edges), any mix of inputs and outputs. The intent's 1x8 row
with 8 in on one side and 3 out on the other works: 8 input edges on the west tiles, 3 output
edges on the east tiles.

### Concerns for Plan 2

- The edge is an entity in the player's belt line that the mod swaps in and out. Plan 2 must
  swap it back to the original belt when the block (or the balancer) goes away, and handle
  blueprints (blueprint the edge as the original belt via `placeable_by` / blueprint setup),
  copy-paste, undo/redo, ghosts, rotation, the upgrade planner (edge per belt tier with
  `next_upgrade`), and mining (gives the belt item back).
- One edge prototype per transport-belt prototype (including modded belts), generated in
  `data-final-fixes`, at that belt's speed. The balancer then runs at min(block tier, belt
  tier) for that belt, like a vanilla splitter would.
- Curves: a belt that turns into the block on its last tile has no straight edge equivalent.
  Either face the edge toward the feeding belt (full throughput, looks straight) or refuse
  the curve; side-loading into an edge fills one lane only.
- Swapping a full tile needs the half-tile overflow rule above (measured to keep every item).
- An edge line is half a tile, so the belt line's buffer is half a tile shorter than with a
  plain belt there (no throughput effect measured).
