# modular-balancer

Factorio 2.1.23 mod (working name). Parent workspace rules in `../CLAUDE.md` apply.

## Constraints

- Factorio 2.1.23 only. `info.json` `factorio_version` is `"2.1"`.
- Before writing mod code, read `../factorio-dev/spec/MODDING-RULES.md` and look every API name up in `../factorio-dev/spec/api/2.1.23/` (runtime-api.json, prototype-api.json). Do not rely on memory.
- Test with fdev (below). Never launch the game by hand.
- FactorioTest suites use plain `assert(cond, "message")`, never luassert.
- Never touch `E:\SteamLibrary\steamapps\common\Factorio` or `%APPDATA%\Factorio`. Never print or commit the token in `%USERPROFILE%\.config\factorio-dev\credentials.json`.
- Plain hand-written Lua, no transpiled runtime. Multiplayer-safe: persistent state only in `storage`, nothing but the three legitimate uses in `on_load`.
- No per-tick or per-item script work in the steady state. Script runs only on build/change events.
- Never lose or duplicate items.
- Local git only. Creating a GitHub remote, pushing or publishing needs the user's approval.
- Prototype names are prefixed `mb-`.

## Test commands

Run from the repo root unless noted.

- Offline unit tests: `..\.tools\lua52\lua52.exe tests/unit/run.lua`
- Static check (from `C:\Users\shimj\Documents\factorio`): `factorio-dev\target\release\fdev.exe lua check modular-balancer`
- In-game tests (same directory): `factorio-dev\target\release\fdev.exe test modular-balancer [--preset vanilla|space-age]`

Unit test contract: each `tests/unit/*_test.lua` returns `{ [name] = function() ... end }`; `run.lua` runs them in sorted order and exits non-zero on any failure.

## Releases

Build a release zip from `git archive` (committed files only), never from the working tree. `.gitattributes` export-ignores `spikes/`, `tests/`, `bench/`, `docs/`, `.emmyrc.json`, `.superpowers/`, `scripts/flow.lua` (test-only) and this file, so a release has no test code, no spikes and no dev marker (`tests/dev.lua`): the dev gate `mb-dev` is then off even for a player who has `factorio-test` enabled. Check with `git archive HEAD | tar -t` before shipping.

## File map

- `info.json`, `settings.lua`, `data.lua`, `data-final-fixes.lua`, `control.lua` - mod entry points (`data-final-fixes.lua` builds the hidden prototypes). `control.lua` has the mod's only `on_init` and `on_configuration_changed` handlers (each can be registered once); later code adds its work to them instead of registering again. `control.lua` hooks FactorioTest when the dev gate `mb-dev` is on; add new suites to its list.
- `settings.lua` - two hidden, forced startup settings: `mb-dev` (on only with `factorio-test` enabled and the committed, export-ignored marker `tests/dev.lua`) gates every piece of test code (`tests/game/data.lua`, `tests/game/remote.lua`, the suites); `mb-spikes` (needs `mb-dev` and the git-ignored `spikes/local-enable.lua`) gates the spikes.
- `prototypes/hidden.lua` - hidden per-tier entities of the balancing network (`mb-hidden-splitter-<tier>`, also the priority splitter, `mb-hidden-linked-belt-<tier>`, `mb-hidden-lane-splitter-<tier>`, `mb-hidden-loader-<tier>`), the buffer chest `mb-hidden-buffer` and the dead-end filter item `mb-hidden-never`, and the edges `mb-edge-in|out-<belt>` (the belt's look, fast-replace group and next upgrade; not `hidden`, so the planner can select them) with their animations `mb-edge-belt-<belt>-<direction>[-odd]` (the half tile a linked belt leaves blank, drawn by `scripts/io.lua`); required from `data-final-fixes.lua`. The turbo tier exists even without Space Age (express copies at turbo speed), so a save that drops Space Age keeps its turbo networks' items.
- `prototypes/blocks.lua` - the visible blocks `mb-balancer-<tier>` (entity `simple-entity-with-owner` with the F1 block mask, item, recipe, unlock by the tier's splitter technology, upgrade chain, placeholder graphics; without Space Age the turbo block and item exist hidden, with no recipe); required from `data.lua`. `locale/en`, `locale/ko` - same keys in both.
- `scripts/groups.lua` - connected groups of same-tier, same-force blocks (`storage.groups`; merge and split on every build/remove, re-key on `on_forces_merged`; each change returns `ids, gone`). `scripts/events.lua` - registers every build/remove/rotate/flip/paste/force-merge event (name filters for blocks, type filters for belt-connectables and inserters, `register_on_object_destroyed` for blocks); the only place these events are registered. Handlers only mark groups dirty (`scripts/balancer.lua`), so bulk changes refresh each group once per batch.
- `scripts/io.lua` - ports of a group (F1, F3, F4): `scan` finds edges, shared tiles, block-tile interfaces and inserter ports (with refusals); `swap`/`unswap` turn a belt tile into an edge `mb-edge-in|out-<belt>` and back, keeping items; `dress` draws an edge's missing half tile (a render object owned by the edge), `dress_all` on configuration changes; `block_port` places the linked belt on a block tile (F3 facing rule); `give_back` undoes a belt built on a block tile (Ruling 6). `scripts/balancer.lua` - live balancing: events mark groups dirty, an `on_nth_tick(1)` handler (registered only while something is dirty, re-set in `on_load`) flushes them once per batch: retire gone groups (networks to the merging group or spilled), scan, swap, rebuild only when N or M changed, link ports and shared tiles, swap unclaimed edges back. `balancer.flush()` runs it at once (tests).
- `scripts/lifecycle.lua` - blueprints and copy-paste (`on_player_setup_blueprint` rewrites edges to the belts they replaced), edge ghosts (become belt ghosts), undo/redo (`on_undo_applied`), the upgrade planner (an edge marked for upgrade, or next to a belt-connectable of its tier marked for upgrade, is swapped back and its belt gets the order), fast-replace and drag over edges (`on_pre_build` swaps the edges under a player's build back to belts first, so items are kept), configuration changes (blocks of a tier whose belt is gone, turbo after Space Age is removed, are replaced by the fastest tier left with their items; a lost hidden surface is replaced) and the hidden surface deleted or cleared at runtime (networks spilled first, then placed again). Edges built by the game (not by the mod) are "loose" in `scripts/balancer.lua` until a group claims them; a block's network goes to whoever mined its last block (`balancer.give`).
- `scripts/gui.lua` - per-balancer settings (Plan 3 Task 3): balance lanes and redistribute unused shares, stored on the group (`scripts/groups.lua`: a merge keeps the larger group's, a split copies them); the settings frame opened by clicking a block (linked custom inputs in `prototypes/inputs.lua`, since a simple-entity-with-owner has no GUI), settings paste (`on_entity_settings_pasted` and the copy/paste-entity-settings controls), blueprint tags `mb_lanes` / `mb_recirc` (written from `lifecycle.on_player_setup_blueprint`, read on build in `scripts/events.lua`). A change marks the group; the flush rebuilds when the settings differ from the network's (`rec.lanes`, `rec.recirc`). Tests: `tests/game/lanes.lua`.
- `scripts/network.lua` - network generator (pure Lua). `scripts/flow.lua` - offline flow model, never required by product code (only test code: `tests/unit`, and `tests/game/exactness.lua` for Ruling 6).
- `scripts/surface.lua` - the hidden surface `mb-hidden` and its region allocator. `scripts/builder.lua` - places a network on it, all or nothing (`place`, `contents`, `destroy`, `rebuild` with item carry-over through a buffer chest).
- `tests/unit/` - offline tests and `run.lua` runner.
- `tests/game/` - FactorioTest suites run by `fdev test` (`placement.lua`, `exactness.lua`, `rebuild.lua`, `groups.lua`, `io.lua`, `play.lua` (live balancing end to end), `lifecycle.lua` (blueprints, undo, ghosts, upgrades, configuration), shared rig `harness.lua`). `tests/mods/mb-test-speed` is a test-only mod for the tier-speed MCP check (F9). Loaded only with the dev gate `mb-dev`: `data.lua` (harness prototypes `mb-test-*`) and `remote.lua` (remote interface `mb-test` for the F6 and groups save/load checks and the F7 benchmark saves on an MCP instance).
- `spikes/` - throwaway research spikes, loaded (prototypes and test suites) only when the hidden startup setting `mb-spikes` is on. It is forced on only when the git-ignored `spikes/local-enable.lua` exists (`return true`, or `return { variant = "<name>" }` for a prototype variant) and `mb-dev` is on; otherwise forced off. An MCP `server_start` instance without `factorio-test` therefore has no spike prototypes. `spikes/multi_belt/repro-load-errors.sh` reproduces the prototype-stage errors of F1. `spikes/hidden_surface/save_load.lua` registers the remote interface `mb-spike-s2` (only with `mb-spikes`) for the F2 save/load check on an MCP instance.
- `docs/feasibility.md` - spike findings (F1..), screenshots in `docs/feasibility/`.
- `bench/` - UPS gate benchmark tooling (Plan 3 Task 1): `builders.lua` (save builders, remote functions `bench_*` of `mb-test`, loaded by `tests/game/remote.lua` behind the dev gate), `ticklens.sh`, `summarize.py`, `tables.py` (round 1), `tables2.py` (round 2), `bench_edge_probe` (edge-join probe). Results in `docs/benchmarks.md` and `docs/benchmarks/raw/`.
- `.emmyrc.json` - editor config (FactorioTest globals whitelisted). `fdev lua check` ignores it and generates its own.
- `.superpowers/` - local planning notes, git-ignored.
