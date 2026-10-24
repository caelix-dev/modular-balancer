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

- `info.json`, `settings.lua`, `data.lua`, `control.lua` - mod entry points. `control.lua` hooks FactorioTest when `factorio-test` is active; add new suites to its list.
- `tests/unit/` - offline tests and `run.lua` runner.
- `tests/game/` - FactorioTest suites run by `fdev test`.
- `spikes/` - throwaway research spikes, loaded (prototypes and test suites) only when the hidden startup setting `mb-spikes` is on. It is forced on only when the git-ignored `spikes/local-enable.lua` exists (`return true`, or `return { variant = "<name>" }` for a prototype variant) and the `factorio-test` mod is enabled; otherwise forced off. An MCP `server_start` instance without `factorio-test` therefore has no spike prototypes. `spikes/multi_belt/repro-load-errors.sh` reproduces the prototype-stage errors of F1. `spikes/hidden_surface/save_load.lua` registers the remote interface `mb-spike-s2` (only with `mb-spikes`) for the F2 save/load check on an MCP instance.
- `docs/feasibility.md` - spike findings (F1..), screenshots in `docs/feasibility/`.
- `.emmyrc.json` - editor config (FactorioTest globals whitelisted). `fdev lua check` ignores it and generates its own.
- `.superpowers/` - local planning notes, git-ignored.
