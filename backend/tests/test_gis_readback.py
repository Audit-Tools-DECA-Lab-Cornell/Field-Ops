from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from pydantic import TypeAdapter

from tests.local_database import admin_sql
from tests.signing import PROJECT

pytestmark = pytest.mark.integration


def read_as_gis(observation_id: UUID) -> tuple[float, float, int, str]:
    result = admin_sql(
        "BEGIN; GRANT fieldmaps_sample_reader TO postgres WITH SET TRUE; "
        "SET LOCAL ROLE fieldmaps_sample_reader; "
        "SELECT json_build_array(longitude, latitude, people, notes)::text "
        "FROM gis.sample_observations WHERE observation_id = :'observation_id'; ROLLBACK;",
        f"observation_id={observation_id}",
    )
    return TypeAdapter(tuple[float, float, int, str]).validate_json(result)


def test_committed_upload_is_immediately_visible_through_restricted_gis_view(
    api_client: TestClient,
) -> None:
    observation_id = uuid4()
    response = api_client.put(
        f"/v1/projects/{PROJECT}/observations/{observation_id}",
        json={
            "site_id": "sample-garden",
            "form_version": "shell-v1",
            "coordinates": [-76.485, 42.448],
            "observer": "QA",
            "people": 3,
            "notes": "GIS readback",
            "observed_at": "2026-09-17T12:00:00Z",
        },
    )
    assert response.status_code == 200
    assert read_as_gis(observation_id) == (-76.485, 42.448, 3, "GIS readback")
