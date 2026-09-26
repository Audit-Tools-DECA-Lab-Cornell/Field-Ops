import subprocess
from shutil import which


def admin_sql(statement: str, *variables: str) -> str:
    docker = which("docker")
    if docker is None:
        msg = "Docker is required for local database tests"
        raise FileNotFoundError(msg)
    result = subprocess.run(  # noqa: S603 - fixed local container, argv only; SQL goes over stdin.
        [
            docker,
            "exec",
            "-i",
            "supabase_db_field-maps",
            "psql",
            "-X",
            "-U",
            "postgres",
            "-d",
            "postgres",
            "-v",
            "ON_ERROR_STOP=1",
            "-Atq",
            *[argument for variable in variables for argument in ("-v", variable)],
        ],
        input=statement,
        text=True,
        capture_output=True,
        check=True,
    )
    return result.stdout.strip()
