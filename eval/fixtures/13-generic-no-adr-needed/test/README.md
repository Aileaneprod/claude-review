# Test layout

From this change on, tests are organised in three layers:

- `test/helpers/` — pure functions shared by tests (formatting, builders).
- `test/fixtures/` — anything that touches I/O or the clock.
- `test/scenarios/` — seed data for integration tests, one directory per
  scenario.

`test/utils/` is retired: new code must not add to it, and its remaining
files move into the layers above as they are touched.
