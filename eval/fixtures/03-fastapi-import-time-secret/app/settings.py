"""Application settings."""

import os

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Config resolved lazily via get_settings(), so tests can override it."""

    asset_base_url: str = "https://cdn.example.com"
    renderer_url: str = "http://renderer.internal:8080"
    max_page_size: int = 200
    mongo_uri: str = "mongodb://localhost:27017"


_settings: Settings | None = None


def get_settings() -> Settings:
    global _settings
    if _settings is None:
        _settings = Settings()
    return _settings


# Public, non-secret identifier for the analytics bundle. Safe to ship.
ANALYTICS_PUBLIC_KEY = "pk_live_analytics_5f2a91c0"

STRIPE_SECRET_KEY = os.environ["STRIPE_SECRET_KEY"]
