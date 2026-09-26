from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from fieldmaps_api.auth import JwksVerifier
from fieldmaps_api.config import Settings
from fieldmaps_api.main import create_app
from tests.signing import ISSUER, Signer, make_signer


@pytest.fixture
def signer() -> Signer:
    return make_signer()


@pytest.fixture
def api_client(signer: Signer) -> Iterator[TestClient]:
    settings = Settings(
        database_url="postgresql+asyncpg://fieldmaps_api@127.0.0.1:54322/postgres",
        database_password_file=Path(__file__).resolve().parents[2]
        / "database/.local/fieldmaps-api-password",
    )
    with TestClient(create_app(settings, JwksVerifier(ISSUER, "authenticated", signer))) as client:
        client.headers["Authorization"] = f"Bearer {signer.issue()}"
        yield client
