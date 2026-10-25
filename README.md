# Modular Balancer

A Factorio 2.1 mod that provides a modular N:M belt balancer. Place 1x1 blocks in any connected shape and attach belts: every belt feeding a block is an input, every belt it feeds is an output, and the group works as an exact N:M balancer. Items are never lost or duplicated, and the steady state does no per-tick script work.

## How it works

- Blocks of the same tier and force that touch edge to edge form one balancer, in any shape. Tiers never join.
- A belt pointing straight into a block is an input; a belt leaving a block straight is an output. Belts running alongside a block are neither. The last tile of each attached belt is replaced by a linked belt of the same belt (an "edge") that is joined to a hidden splitter network; removing the block puts the belt back with its items.
- Every output gets an equal share of the input, inputs are drawn equally when the outputs back up, and the share an output does not take is spread equally over the others.
- Inserters taking from a block count as one more output of that block (several inserters on one block split that block's share); inserters putting into a block count as one input.
- Removing the last block of a balancer hands everything inside its network to whoever removed it (a player's inventory, a robot's storage chests, a space platform's hub). A large, full balancer can hold thousands of items. When it is destroyed (nobody mines it) they are spilled next to it, never on its tiles, marked for construction robots to collect.

## Limits

- Refused, with a message where it happens:
  - a curved last tile into a block (make the last tile straight);
  - a belt leaving a block that is side-loaded (it is not an output);
  - more than one underground belt, splitter or circuit-wired belt per block (each uses the block's own tile);
  - inserters that both take from and put into the same block;
  - a belt of another force.
- Loaders next to a block are ignored.
- Size: there is no limit on the number of inputs or outputs, but the hidden network grows with them and costs engine time like any splitter network of that size. Examples (splitters, with recirculation): 8:3 about 38, 64:64 about 860, 96:96 about 2 560, 128:128 about 1 980, 160:160 about 5 920. The size jumps just above each power of two (96:96 is larger than 128:128). Changing the number of inputs or outputs of a full 64:64 (about 30 000 items) rebuilds it in about 0.5 s, during which the game pauses; ten such rebuilds at once pause it for about 6 s (docs/benchmarks.md).

Blueprints, copy-paste, undo/redo, ghosts and the upgrade planner work with balancers: a blueprint holds the blocks and the player's own belts, and the mod connects them again where they are built.

The last tile of a belt next to a block looks and behaves like that belt: belts can be dragged across it, a faster belt or an underground belt placed on it, and the mod connects the new tile again (items on it are kept, as with vanilla belts). A belt placed over that tile by another mod's script (not by a player) loses the items on that tile; robots do not, because the upgrade goes to a plain belt (below).

Upgrade planner: an unconfigured planner selects the edge tile like a belt. A configured one (for example fast belt to express belt) never selects it, but when it marks the belt, underground belt or splitter next to it with the same tier, the edge tile gets the same order, so one pass upgrades the whole line. Limits: until robots (or the player) upgrade it, that tile is not connected to the balancer, and the balancer rebuilds once when it drops out and once when it is back. A balancer whose inputs or outputs are all waiting for an upgrade stops (its items are kept). With a configured planner, a line whose only selected tile is the edge keeps the old belt tier.

Undo limits: undoing a rotation that turned an edge into the other role (input to output) does nothing; rotate it back by hand.

Status: in development (version 0.0.1). Playable for testing; the graphics are placeholders.
