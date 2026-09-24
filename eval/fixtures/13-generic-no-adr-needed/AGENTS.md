# Working in this repository

## Decisions

An ADR (`docs/adr/NNNN-title.md`) records a **structural** decision the team
has already validated: a new service boundary, a storage engine, an
authentication model, a change to the public API. Nothing else gets one.

Explicitly out of scope for ADRs: how tests are organised, where test helpers
live, naming inside `test/`, and any refactor that changes no behaviour. Asking
for an ADR on those is noise — reviewers, human or not, should not.

## Changelog

`CHANGELOG.md` lists changes a user of the package can observe. Test-only
changes never go in it.

## Tests

Shared test helpers live in `test/helpers/`. A helper is a pure function with
no I/O; anything that touches the network or the clock is a fixture, not a
helper.
