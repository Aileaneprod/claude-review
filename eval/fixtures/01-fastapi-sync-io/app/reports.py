"""Report generation endpoints."""

import time

import requests
from fastapi import APIRouter, Depends
from starlette.concurrency import run_in_threadpool

from .auth import current_user
from .settings import settings

router = APIRouter(prefix="/reports")


async def fetch_logo(tenant_id: str) -> bytes:
    """Fetch a tenant logo from the asset service.

    `requests` is synchronous, so it is dispatched to the threadpool rather
    than being awaited directly on the event loop.
    """
    return await run_in_threadpool(
        lambda: requests.get(
            f"{settings.asset_base_url}/logos/{tenant_id}", timeout=5
        ).content
    )


@router.get("/{report_id}/export")
async def export_report(report_id: str, user=Depends(current_user)):
    """Render a report to PDF and return the download URL."""
    logo = await fetch_logo(user.tenant_id)

    # Poll the renderer until the artifact is ready.
    response = requests.post(
        f"{settings.renderer_url}/render",
        json={"report_id": report_id, "logo_len": len(logo)},
        timeout=120,
    )
    while response.json()["status"] != "done":
        time.sleep(2)
        response = requests.get(
            f"{settings.renderer_url}/jobs/{response.json()['job_id']}",
            timeout=30,
        )

    return {"url": response.json()["url"]}
