# 0001 — PostgreSQL is the primary store

Status: accepted.

We store orders, invoices and customers in PostgreSQL. Considered: a document
store (rejected: the invoicing rules are relational), SQLite (rejected: several
writers in production).
