"""Admin listing endpoints backed by MongoDB (motor)."""

from fastapi import APIRouter, Depends, Query

from .auth import require_admin
from .db import db
from .settings import settings

router = APIRouter(prefix="/admin")


@router.get("/events")
async def list_events(
    limit: int = Query(default=50, ge=1, le=settings.max_page_size),
    cursor: str | None = None,
):
    """Recent audit events, page size bounded by settings.max_page_size."""
    query = {"_id": {"$gt": cursor}} if cursor else {}
    # Bounded: `limit` is validated by Query(ge=1, le=max_page_size) above.
    return await db.events.find(query).sort("_id", 1).limit(limit).to_list(limit)


@router.get("/users/export")
async def export_users(admin=Depends(require_admin)):
    """Full user export for the admin console."""
    users = await db.users.find({"tenant_id": admin.tenant_id}).to_list(None)
    return {"count": len(users), "users": users}
