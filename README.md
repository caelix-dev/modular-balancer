# Modular Balancer

A Factorio 2.1 mod that provides a modular N:M belt balancer. Place 1x1 blocks in any connected shape and attach belts: every belt feeding a block is an input, every belt it feeds is an output, and the group works as an exact N:M balancer. Items are never lost or duplicated, and the steady state does no per-tick script work.

## How it works

- Blocks of the same tier and force that touch edge to edge form one balancer, in any shape. Tiers never join.
- A belt pointing straight into a block is an input; a belt leaving a block straight is an output. Belts running alongside a block are neither. The last tile of each attached belt is replaced by a linked belt of the same belt (an "edge") that is joined to a hidden splitter network; removing the block puts the belt back with its items.
- Every output gets an equal share of the input, inputs are drawn equally when the outputs back up, and the share an output does not take is spread equally over the others.
- Inserters taking from a block count as one more output of that block (several inserters on one block split that block's share); inserters putting into a block count as one input.
- Removing the last block of a balancer hands everything inside its network to whoever removed it (a player's inventory, a robot's storage chests, a space platform's hub). A large, full balancer can hold thousands of items. When it is destroyed (nobody mines it) they are spilled next to it, never on its tiles, marked for construction robots to collect; on a space platform they go to the platform's hub instead (as does whatever a player's inventory cannot take), and only what the hub refuses is spilled, never onto empty space.

## Settings

Click a block to open its balancer's settings (E, Esc or the close button closes them; they also close when the block is removed or you walk out of reach). They open for blocks within reach, or from remote view. They apply to the whole balancer:

- **Balance lanes** (off by default): both lanes of every output carry the same, even when the inputs fill only one lane.
- **Redistribute unused shares** (on by default): what one output does not take goes back into the balancer, so the other outputs stay equal. Turning it off uses a smaller hidden network that costs less game update time (close to Better Belt Balancer at some ratios, up to about 1.5x at others). The outputs are still equal while they all run freely, but a slow output then passes its unused share to one neighbour only.

Changing a setting rebuilds the balancer once; its items are kept. If that rebuild fails, the balancer keeps its old network and the settings switch back to match it. Copy-paste settings (Shift + right click, Shift + left click on another block) copies the copied balancer's settings as they are when you paste, and blueprints and copy-paste keep them. When two balancers are joined, the joined balancer keeps the settings of the one with more blocks; when one is split, every part keeps its settings. A block that joins an existing balancer takes that balancer's settings, so a pasted blueprint touching an existing balancer can end up with either side's settings, depending on which blocks are built first. Servers: players whose permission group may not open entity GUIs or paste entity settings cannot change these settings either.

## Limits

- Refused, with a message where it happens:
  - a curved last tile into a block (make the last tile straight);
  - a belt leaving a block that is side-loaded (it is not an output);
  - more than one underground belt, splitter or circuit-wired belt per block (each uses the block's own tile);
  - inserters that both take from and put into the same block;
  - a belt of another force.
- Loaders next to a block are ignored.
- Size: there is no limit on the number of inputs or outputs, but the hidden network grows with them and costs engine time like any splitter network of that size. Examples (splitters, with recirculation): 8:3 about 38, 64:64 about 860, 96:96 about 2 560, 128:128 about 1 980, 160:160 about 5 920. The size jumps just above each power of two (96:96 is larger than 128:128).
- Rebuilds are spread over ticks: a balancer whose number of inputs or outputs changes builds its new network a little each tick while the old one keeps running, then switches over, and the old network's items move into the new one over the next ticks. A full 64:64 (about 30 000 items) takes about 25 ticks, ten of them about 220 ticks (3.5 s), and removing ten full ones about 140 ticks, with no single tick much over 100 ms. The longest tick is the one that computes a large network's layout, which cannot be split: about 80-120 ms for 64:65, more for larger balancers. Before, the same rebuilds paused the game for 0.5-0.7 s and 6-8 s. While the old network's items move over, they wait inside it (they do not flow), and after a big shrink most of them go through the new network's buffer, which feeds input 1 at up to half a belt. If that buffer cannot take more (very many kinds of items that do not stack together), the rest waits in the old network, a message says so, and it moves over once there is room; nothing is lost.
- An item that spoils into a creature (a biter or pentapod egg) and spoils inside a balancer vanishes: nothing hatches inside the hidden network, which cannot be damaged anyway.

Blueprints, copy-paste, undo/redo, ghosts and the upgrade planner work with balancers: a blueprint holds the blocks and the player's own belts, and the mod connects them again where they are built.

The last tile of a belt next to a block looks like that belt, but nothing can be built over it: a belt dragged across it goes under it with underground belts, as across any building, so a crossing line never merges into a balancer's input or output. To change its tier, use the upgrade planner on the belt line (the last tile follows it, items kept), or mine it and place the new belt.

Upgrade planner: the planner never selects the edge tile itself (it is not in the planner's lists), but when it marks the belt, underground belt or splitter next to it with the same tier, the edge tile gets the same order, so one pass upgrades the whole line. Limits: until robots (or the player) upgrade it, that tile is not connected to the balancer, and the balancer rebuilds once when it drops out and once when it is back. A balancer whose inputs or outputs are all waiting for an upgrade stops (its items are kept). A selection that holds only the edge tile changes nothing. The same applies to a belt of another tier placed with Shift over that tile: the game orders an upgrade instead of building it, and the balancer drops that port at once until robots (or the player) build it.

Undo limits: undoing a rotation that turned an edge into the other role (input to output) does nothing; rotate it back by hand. Undoing the removal of a whole balancer brings its blocks back with the default settings (balance lanes off, redistribute on).

A blueprint holding a different belt (another tier or direction) pasted over the last tile next to a block does not upgrade it in place: the game marks that tile for deconstruction and places a ghost, and robots replace it (items kept, the balancer drops that port until then).

Status: in development (version 0.0.1). Playable for testing; the graphics are placeholders.
