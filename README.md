# Modular Balancer

A Factorio 2.1 mod that adds a modular N:M belt balancer. Place 1x1 blocks in any connected shape and attach belts: every belt feeding a block is an input, every belt it feeds is an output, and the group works as an exact N:M balancer. Items are never lost or duplicated, and the steady state does no per-tick script work.

Version 0.1.4, for Factorio 2.1. Space Age is optional. MIT License.

## Blocks

There is one block per belt tier: basic, fast, express and turbo. A block is crafted from the tier's splitter and 5 of the tier's belts, and is unlocked by the technology that unlocks that splitter. Without Space Age the turbo block cannot be crafted. Every tier weighs 20 kg, so a rocket carries 50 (one stack).

Characters and vehicles can walk and drive over blocks, as over belts. Blocks cannot overlap buildings, inserters, rails, trees, water or other blocks.

## How it works

- Blocks of the same tier and force that touch edge to edge form one balancer, in any shape. Different tiers never join.
- A belt pointing straight into a block is an input; a belt leaving a block straight is an output. Belts running alongside a block are neither.
- The last tile of each attached belt is replaced by a linked belt that looks like the same belt (an "edge"), joined to a hidden splitter network. Removing the block puts the belt back with its items.
- Every output gets an equal share of the input. When the outputs back up, the inputs are drawn equally. The share one output does not take is spread equally over the others.
- Inserters taking from a block count as one more output of that block (several inserters on one block split that block's share). Inserters putting into a block count as one input.
- Each block's look follows its neighbours, so a group reads as one machine.

## Settings

Click a block to open its balancer's settings. E, Esc or the close button closes them, and they also close when the block is removed or you walk out of reach. They open for blocks within reach, or from remote view. The settings apply to the whole balancer:

- **Balance lanes** (off by default): both lanes of every output carry the same, even when the inputs fill only one lane.
- **Redistribute unused shares** (on by default): what one output does not take goes back into the balancer, so the other outputs stay equal. Turning it off uses a smaller hidden network that costs less game update time (close to Better Belt Balancer at some ratios, up to about 1.5x at others). The outputs are still equal while they all run freely, but a slow output then passes its unused share to one neighbour only.

Changing a setting rebuilds the balancer once; its items are kept. If that rebuild fails, the balancer keeps its old network and the settings switch back to match it.

How settings travel:

- **Copy and paste settings** (Shift + right click, then Shift + left click on another block) copies the copied balancer's settings as they are when you paste.
- **Blueprints and copy-paste** keep them.
- **Two balancers joined:** the joined balancer keeps the settings of the one with more blocks.
- **One balancer split:** every part keeps its settings.
- **A block that joins an existing balancer** takes that balancer's settings. A pasted blueprint touching an existing balancer can therefore end up with either side's settings, depending on which blocks are built first.

On servers, players whose permission group may not open entity GUIs or paste entity settings cannot change these settings either.

## Building and editing

Blueprints, copy-paste, undo/redo, ghosts and the upgrade planner work with balancers. A blueprint holds the blocks and the player's own belts, and the mod connects them again where they are built.

**Belts across and along an edge.** The edge tile next to a block looks like its belt.
- A belt dragged across it goes under it with underground belts, as across a perpendicular belt, so a crossing line never merges into a balancer's input or output.
- A belt line dragged along it in its direction replaces it like a vanilla belt (to upgrade it; items kept).
- A single belt clicked straight onto it is refused.

**Block ghosts on belts.** A block ghost placed on a belt (for example a forced ghost build with Shift) marks the belt for deconstruction, and the block replaces it, keeping the belt and its items. A block built by hand directly on a belt is refused, and so is a belt built on a block.

**Upgrade planner.**
- The planner never selects the edge tile itself (it is not in the planner's lists).
- When the planner marks the belt, underground belt or splitter next to the edge with the same tier, the edge tile gets the same order, so one pass upgrades the whole line.
- Until robots (or the player) upgrade it, that tile is not connected to the balancer. The balancer rebuilds once when it drops out and once when it is back.
- A balancer whose inputs or outputs are all waiting for an upgrade stops; its items are kept.
- A selection that holds only the edge tile changes nothing.
- A belt of another tier placed with Shift over the edge tile behaves the same way: the game orders an upgrade instead of building it, and the balancer drops that port at once until robots (or the player) build it.

**Blueprints over an edge.** A blueprint holding a different belt (another tier or direction) pasted over the edge tile does not upgrade it in place. The game marks that tile for deconstruction and places a ghost, and robots replace it. Items are kept, and the balancer drops that port until then.

**Undo.**
- Undoing a rotation that turned an edge into the other role (input to output) does nothing; rotate it back by hand.
- Undoing the removal of a whole balancer brings its blocks back with the default settings (balance lanes off, redistribute on).

## Removing a balancer

Removing the last block of a balancer hands everything inside its network to whoever removed it: a player's inventory, a robot's storage chests, or a space platform's hub. A large, full balancer can hold thousands of items.

When a balancer is destroyed (nobody mines it), its items are spilled next to it, never on its tiles, and marked for construction robots to collect. On a space platform they go to the platform's hub instead, as does whatever a player's inventory cannot take. Only what the hub refuses is spilled, and never onto empty space.

## Limits

These are refused, with a message where it happens:

- a curved last tile into a block (make the last tile straight);
- a belt leaving a block that is side-loaded (it is not an output);
- more than one underground belt, splitter or circuit-wired belt per block (each uses the block's own tile);
- inserters on a block that already uses its tile for an underground belt, splitter or circuit-wired belt;
- inserters that both take from and put into the same block;
- a belt of another force.

Other limits:

- Loaders next to a block are ignored.
- **Size:** there is no limit on the number of inputs or outputs. The hidden network grows with them and costs engine time like any splitter network of that size. Examples (splitters, with recirculation): 8:3 about 38, 64:64 about 860, 96:96 about 2 560, 128:128 about 1 980, 160:160 about 5 920. The size jumps just above each power of two, so 96:96 is larger than 128:128.
- **Rebuilds are spread over ticks.** A balancer whose number of inputs or outputs changes builds its new network a little each tick while the old one keeps running. It then switches over, and the old network's items move into the new one over the next ticks.
  - A full 64:64 (about 30 000 items) takes about 25 ticks.
  - Ten of them take about 220 ticks (3.5 s), and removing ten full ones about 140 ticks, with no single tick much over 100 ms.
  - The longest tick is the one that computes a large network's layout, which cannot be split: about 80-120 ms for 64:65, more for larger balancers.
  - While the old network's items move over, they wait inside it and do not flow. After a big shrink, most of them go through the new network's buffer, which feeds input 1 at up to half a belt.
  - If that buffer cannot take more (very many kinds of items that do not stack together), the rest waits in the old network and a message says so. It moves over once there is room; nothing is lost.
- An item that spoils into a creature (a biter or pentapod egg) and spoils inside a balancer vanishes: nothing hatches inside the hidden network, which cannot be damaged anyway.
- **Removed tiers:** if a tier's belt no longer exists (for example turbo after Space Age is removed), its blocks are replaced by the fastest tier left, with their items.

## Performance

The steady state runs no script at all; the cost is the engine's own update of the hidden splitter network. With redistribution on, that is about 1.3x-2.1x Better Belt Balancer's total update time at the ratios measured; with it off, about 1.0x-1.5x. The measurements are in [docs/benchmarks.md](docs/benchmarks.md).
