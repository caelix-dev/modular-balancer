-- Dev marker: its presence turns the hidden startup setting `mb-dev` on (settings.lua) when the
-- factorio-test mod is enabled. `tests/` is export-ignored (.gitattributes), so a release zip
-- built with `git archive` has no marker, and then neither the test prototypes
-- (tests/game/data.lua), the `mb-test` remote interface (tests/game/remote.lua), the test suites
-- nor the spikes load, even for a player who has factorio-test enabled.
return true
