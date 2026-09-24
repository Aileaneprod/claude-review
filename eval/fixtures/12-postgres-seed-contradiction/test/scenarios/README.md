# Billing scenarios

Seed data for the billing integration tests. Every row below is referentially
closed (each foreign key points at a row in this seed) and temporally closed
(no event is dated before the account it belongs to was created). The CI job
`scenario-integrity` checks both.

| account | scenario |
|---|---|
| 1 | Active customer, two paid invoices. |
| 2 | Active customer, one invoice still open. |
| 3 | Signed up, **never activated**: no service was ever delivered, so nothing may have been billed or paid. |
| 4 | Active customer whose second order was cancelled. Its invoice was voided before payment; a `void` invoice is the expected trace of a cancellation, not an error. |
