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

Build a release zip from `git archive` (committed files only), never from the working tree, so the git-ignored `spikes/local-enable.lua` cannot ship. Even if it did, it does nothing without `factorio-test`. Consider leaving `spikes/` out of release zips entirely.

## File map

- `info.json`, `settings.lua`, `data.lua`, `data-final-fixes.lua`, `control.lua` - mod entry points (`data-final-fixes.lua` builds the hidden prototypes). `control.lua` has the mod's only `on_init` and `on_configuration_changed` handlers (each can be registered once); later code adds its work to them instead of registering again. `control.lua` hooks FactorioTest when `factorio-test` is active; add new suites to its list.
- `prototypes/hidden.lua` - hidden per-tier entities of the balancing network (`mb-hidden-splitter-<tier>`, also the priority splitter, `mb-hidden-linked-belt-<tier>`, `mb-hidden-lane-splitter-<tier>`, `mb-hidden-loader-<tier>`), the buffer chest `mb-hidden-buffer` and the dead-end filter item `mb-hidden-never`; required from `data-final-fixes.lua`.
- `prototypes/blocks.lua` - the visible blocks `mb-balancer-<tier>` (entity `simple-entity-with-owner` with the F1 block mask, item, recipe, unlock by the tier's splitter technology, upgrade chain, placeholder graphics); required from `data.lua`. `locale/en`, `locale/ko` - same keys in both.
- `scripts/groups.lua` - connected groups of same-tier, same-force blocks (`storage.groups`; merge and split on every build/remove, re-key on `on_forces_merged`; each change returns `ids, gone`). `scripts/events.lua` - registers every build/remove/rotate/flip/paste/force-merge event (name filters for blocks, type filters for belt-connectables and inserters, `register_on_object_destroyed` for blocks); the only place these events are registered. Handlers only mark groups dirty (`scripts/balancer.lua`), so bulk changes refresh each group once per batch.
- `scripts/io.lua` - ports of a group (F1, F3, F4): `scan` finds edges, shared tiles, block-tile interfaces and inserter ports (with refusals); `swap`/`unswap` turn a belt tile into an edge `mb-edge-in|out-<belt>` and back, keeping items; `block_port` places the linked belt on a block tile (F3 facing rule); `give_back` undoes a belt built on a block tile (Ruling 6). `scripts/balancer.lua` - live balancing: events mark groups dirty, an `on_nth_tick(1)` handler (registered only while something is dirty, re-set in `on_load`) flushes them once per batch: retire gone groups (networks to the merging group or spilled), scan, swap, rebuild only when N or M changed, link ports and shared tiles, swap unclaimed edges back. `balancer.flush()` runs it at once (tests).
- `scripts/network.lua` - network generator (pure Lua). `scripts/flow.lua` - offline flow model, never required by product code (only test code: `tests/unit`, and `tests/game/exactness.lua` for Ruling 6).
- `scripts/surface.lua` - the hidden surface `mb-hidden` and its region allocator. `scripts/builder.lua` - places a network on it, all or nothing (`place`, `contents`, `destroy`, `rebuild` with item carry-over through a buffer chest).
- `tests/unit/` - offline tests and `run.lua` runner.
- `tests/game/` - FactorioTest suites run by `fdev test` (`placement.lua`, `exactness.lua`, `rebuild.lua`, `groups.lua`, `io.lua`, `play.lua` (live balancing end to end), shared rig `harness.lua`). `tests/mods/mb-test-speed` is a test-only mod for the tier-speed MCP check (F9). Loaded only with `factorio-test`: `data.lua` (harness prototypes `mb-test-*`) and `remote.lua` (remote interface `mb-test` for the F6 and groups save/load checks and the F7 benchmark saves on an MCP instance).
- `spikes/` - throwaway research spikes, loaded (prototypes and test suites) only when the hidden startup setting `mb-spikes` is on. It is forced on only when the git-ignored `spikes/local-enable.lua` exists (`return true`, or `return { variant = "<name>" }` for a prototype variant) and the `factorio-test` mod is enabled; otherwise forced off. An MCP `server_start` instance without `factorio-test` therefore has no spike prototypes. `spikes/multi_belt/repro-load-errors.sh` reproduces the prototype-stage errors of F1. `spikes/hidden_surface/save_load.lua` registers the remote interface `mb-spike-s2` (only with `mb-spikes`) for the F2 save/load check on an MCP instance.
- `docs/feasibility.md` - spike findings (F1..), screenshots in `docs/feasibility/`.
- `.emmyrc.json` - editor config (FactorioTest globals whitelisted). `fdev lua check` ignores it and generates its own.
- `.superpowers/` - local planning notes, git-ignored.
