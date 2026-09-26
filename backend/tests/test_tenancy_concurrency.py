from collections.abc import Iterator
from hashlib import sha256
from pathlib import Path
from uuid import UUID, uuid4

import anyio
import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy.pool import NullPool

from fieldmaps_api.config import Settings
from fieldmaps_api.database import database_connection
from tests.local_database import admin_sql

pytestmark = pytest.mark.integration
PASSWORD_FILE = Path(__file__).resolve().parents[2] / "database/.local/fieldmaps-api-password"


@pytest.fixture
def tenancy() -> Iterator[tuple[UUID, UUID, UUID, UUID, str]]:
    owner, first, second, org, project = (uuid4() for _ in range(5))
    digest = sha256(uuid4().bytes).hexdigest()
    variables = (
        f"owner={owner}",
        f"first={first}",
        f"second={second}",
        f"org={org}",
        f"project={project}",
        f"digest={digest}",
    )
    admin_sql(
        "INSERT INTO auth.users(id, instance_id, aud, role, email) "
        "SELECT id, '00000000-0000-0000-0000-000000000000'::uuid, "
        "'authenticated','authenticated', id::text || '@test.invalid' "
        "FROM (VALUES (:'owner'::uuid),(:'first'::uuid),(:'second'::uuid)) u(id); "
        "INSERT INTO fieldmaps.profiles(user_id) VALUES (:'owner'),(:'first'),(:'second'); "
        "INSERT INTO fieldmaps.organizations(id,name,slug) "
        "VALUES (:'org','Concurrent team',:'org'); "
        "INSERT INTO fieldmaps.projects(id,organization_id,name,code) "
        "VALUES (:'project',:'org','Concurrent project','concurrent-project'); "
        "INSERT INTO fieldmaps.organization_members(organization_id,user_id,role) "
        "VALUES (:'org',:'owner','owner'); "
        "INSERT INTO fieldmaps.project_memberships(user_id,organization_id,project_id,role) "
        "VALUES (:'owner',:'org',:'project','manager'); "
        "INSERT INTO fieldmaps.invitations(organization_id,project_id,role,token_hash, "
        "expires_at,max_uses,created_by) "
        "VALUES (:'org',:'project','observer',:'digest',now()+interval '1 day',1,:'owner');",
        *variables,
    )
    try:
        yield first, second, org, project, digest
    finally:
        admin_sql(
            "DELETE FROM fieldmaps.invitations WHERE organization_id=:'org'; "
            "DELETE FROM fieldmaps.project_memberships WHERE organization_id=:'org'; "
            "DELETE FROM fieldmaps.organization_members WHERE organization_id=:'org'; "
            "DELETE FROM fieldmaps.projects WHERE organization_id=:'org'; "
            "DELETE FROM fieldmaps.organizations WHERE id=:'org'; "
            "DELETE FROM auth.users WHERE id IN (:'owner',:'first',:'second');",
            *variables,
        )


async def act_together(first: UUID, second: UUID, statement: str, target: str) -> list[str]:
    connection = database_connection(
        Settings(
            database_url="postgresql+asyncpg://fieldmaps_api@127.0.0.1:54322/postgres",
            database_password_file=PASSWORD_FILE,
        )
    )
    engine = create_async_engine(connection.url, poolclass=NullPool)
    results: list[str] = []
    ready = anyio.Event()
    arrived = 0

    async def act(user: UUID) -> None:
        nonlocal arrived
        try:
            async with engine.begin() as transaction:
                await transaction.execute(
                    text("SELECT set_config('fieldmaps.user_id', :user, true)"), {"user": str(user)}
                )
                arrived += 1
                if arrived == 2:
                    ready.set()
                await ready.wait()
                await transaction.execute(
                    text(statement),
                    {"target": target, "user": user},
                )
            results.append("accepted")
        except DBAPIError as error:
            results.append(str(error.orig))

    try:
        with anyio.fail_after(20):
            async with anyio.create_task_group() as group:
                group.start_soon(act, first)
                group.start_soon(act, second)
    finally:
        await engine.dispose()
    return results


def test_single_use_invitation_accepts_only_one_concurrent_redemption(
    tenancy: tuple[UUID, UUID, UUID, UUID, str],
) -> None:
    first, second, org, project, digest = tenancy
    results = anyio.run(
        act_together,
        first,
        second,
        "SELECT fieldmaps_private.redeem_invitation(:target, NULL)",
        digest,
    )
    assert results.count("accepted") == 1
    assert sum("invitation_invalid" in result for result in results) == 1
    assert (
        admin_sql(
            "SELECT count(*) FROM fieldmaps.project_memberships "
            "WHERE project_id=:'project' AND user_id IN (:'first',:'second'); "
            "SELECT use_count FROM fieldmaps.invitations WHERE organization_id=:'org';",
            f"project={project}",
            f"first={first}",
            f"second={second}",
            f"org={org}",
        )
        == "1\n1"
    )


def test_concurrent_demotions_cannot_remove_both_project_managers(
    tenancy: tuple[UUID, UUID, UUID, UUID, str],
) -> None:
    first, second, org, project, _ = tenancy
    admin_sql(
        "DELETE FROM fieldmaps.project_memberships WHERE project_id=:'project'; "
        "INSERT INTO fieldmaps.project_memberships(user_id,organization_id,project_id,role) "
        "VALUES (:'first',:'org',:'project','manager'), (:'second',:'org',:'project','manager');",
        f"project={project}",
        f"first={first}",
        f"second={second}",
        f"org={org}",
    )
    results = anyio.run(
        act_together,
        first,
        second,
        "SELECT fieldmaps_private.set_project_role(CAST(:target AS uuid), :user, 'viewer')",
        str(project),
    )
    assert results.count("accepted") == 1
    assert sum("sole_owner" in result for result in results) == 1
    assert (
        admin_sql(
            "SELECT count(*) FROM fieldmaps.project_memberships "
            "WHERE project_id=:'project' AND role='manager';",
            f"project={project}",
        )
        == "1"
    )
