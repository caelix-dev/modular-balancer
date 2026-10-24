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

## File map

- `info.json`, `data.lua`, `control.lua` - mod entry points. `control.lua` hooks FactorioTest when `factorio-test` is active; add new suites to its list.
- `tests/unit/` - offline tests and `run.lua` runner.
- `tests/game/` - FactorioTest suites run by `fdev test`.
- `.emmyrc.json` - editor/analyzer config (FactorioTest globals whitelisted).
- `.superpowers/` - local planning notes, git-ignored.
