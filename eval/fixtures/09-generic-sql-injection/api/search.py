"""Search endpoints."""

from enum import Enum

from .db import connection

SORT_COLUMNS = {"created_at", "name", "score"}


class SortDirection(str, Enum):
    ASC = "ASC"
    DESC = "DESC"


def list_products(sort_by: str, direction: SortDirection, limit: int = 50):
    """Sort column is checked against an allow-list; direction is an Enum.

    Neither value can be attacker-controlled by the time it reaches the query.
    """
    if sort_by not in SORT_COLUMNS:
        raise ValueError(f"invalid sort column: {sort_by}")

    sql = f"SELECT id, name FROM products ORDER BY {sort_by} {direction.value} LIMIT %s"
    with connection.cursor() as cur:
        cur.execute(sql, (limit,))
        return cur.fetchall()


def search_customers(term: str):
    """Free-text customer search."""
    sql = (
        "SELECT id, email FROM customers "
        f"WHERE email LIKE '%{term}%' OR name LIKE '%{term}%'"
    )
    with connection.cursor() as cur:
        cur.execute(sql)
        return cur.fetchall()
