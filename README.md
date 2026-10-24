# Modular Balancer

A Factorio 2.1 mod that provides a modular N:M belt balancer. Place 1x1 blocks in any connected shape and attach belts: every belt feeding a block is an input, every belt it feeds is an output, and the group works as an exact N:M balancer. Items are never lost or duplicated, and the steady state does no per-tick script work.

Blueprints, copy-paste, undo/redo, ghosts and the upgrade planner work with balancers: a blueprint holds the blocks and the player's own belts, and the mod connects them again where they are built.

Limits of the upgrade planner: it never selects the mod's edge tiles (the last tile of a belt next to a block) itself. When it marks the belt next to an edge, the edge tile gets the same order; until robots (or the player) upgrade it, that belt is not connected to the balancer, and the balancer rebuilds once when it drops out and once when it is back. A balancer whose inputs or outputs are all waiting for an upgrade stops (its items are kept). An edge fed by an underground belt or a splitter, or a line whose only selected tile is the edge, keeps the old belt tier.

Undo limits: undoing a rotation that turned an edge into the other role (input to output) does nothing; rotate it back by hand.

Status: in development (version 0.0.1). Playable for testing; the graphics are placeholders.
