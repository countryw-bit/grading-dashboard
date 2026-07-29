from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator
import platform
import sys

import oracledb
from app.config import settings

BASE_DIR = Path(__file__).resolve().parent.parent
SQL_DIR = BASE_DIR / "sql"

_ORACLE_INIT_ERROR: str | None = None
_ORACLE_CLIENT_VERSION: str | None = None

def initialize_oracle_client() -> None:
    global _ORACLE_INIT_ERROR, _ORACLE_CLIENT_VERSION
    if not settings.oracle_client_dir:
        return
    client_dir = Path(settings.oracle_client_dir)
    if not client_dir.exists():
        _ORACLE_INIT_ERROR = f"ORACLE_CLIENT_DIR does not exist: {client_dir}"
        return
    if not (client_dir / "oci.dll").exists():
        _ORACLE_INIT_ERROR = f"oci.dll was not found in ORACLE_CLIENT_DIR: {client_dir}"
        return
    try:
        oracledb.init_oracle_client(lib_dir=str(client_dir))
        _ORACLE_CLIENT_VERSION = ".".join(map(str, oracledb.clientversion()))
    except Exception as exc:
        _ORACLE_INIT_ERROR = f"{type(exc).__name__}: {exc}"

initialize_oracle_client()

def validate_identifier(value: str) -> str:
    cleaned = value.strip().upper()
    if not cleaned or not cleaned.replace("_", "").isalnum():
        raise ValueError(f"Unsafe Oracle identifier: {value!r}")
    return cleaned

def load_sql(filename: str) -> str:
    path = SQL_DIR / filename
    if not path.exists():
        raise FileNotFoundError(f"SQL file was not found: {path}")
    return path.read_text(encoding="utf-8").replace(
        "{{SCHEMA}}", validate_identifier(settings.oracle_schema)
    )

def build_dsn() -> str:
    if not settings.oracle_host:
        raise RuntimeError("ORACLE_HOST is not configured in .env")
    if settings.oracle_service_name:
        return oracledb.makedsn(
            settings.oracle_host,
            settings.oracle_port,
            service_name=settings.oracle_service_name,
        )
    if settings.oracle_sid:
        return oracledb.makedsn(
            settings.oracle_host,
            settings.oracle_port,
            sid=settings.oracle_sid,
        )
    raise RuntimeError("Configure either ORACLE_SID or ORACLE_SERVICE_NAME in .env")

def build_dsn_preview() -> str:
    target = (
        f"service_name={settings.oracle_service_name}"
        if settings.oracle_service_name
        else f"sid={settings.oracle_sid or '(not configured)'}"
    )
    return f"{settings.oracle_host or '(not configured)'}:{settings.oracle_port} ({target})"

def oracle_runtime_info() -> dict[str, Any]:
    client_dir = Path(settings.oracle_client_dir) if settings.oracle_client_dir else None
    return {
        "driver_version": oracledb.__version__,
        "driver_mode": "Thin" if oracledb.is_thin_mode() else "Thick",
        "client_dir": settings.oracle_client_dir or "(not configured)",
        "client_dir_exists": bool(client_dir and client_dir.exists()),
        "oci_exists": bool(client_dir and (client_dir / "oci.dll").exists()),
        "client_version": _ORACLE_CLIENT_VERSION or "(not loaded)",
        "initialization_error": _ORACLE_INIT_ERROR,
        "host": settings.oracle_host or "(not configured)",
        "port": settings.oracle_port,
        "sid": settings.oracle_sid,
        "service_name": settings.oracle_service_name,
        "schema": settings.oracle_schema,
        "python_version": sys.version.split()[0],
        "python_architecture": platform.architecture()[0],
        "platform": platform.platform(),
        "dsn_preview": build_dsn_preview(),
    }

@contextmanager
def oracle_connection(username: str, password: str) -> Iterator[oracledb.Connection]:
    if _ORACLE_INIT_ERROR:
        raise RuntimeError(f"Oracle Client initialization failed: {_ORACLE_INIT_ERROR}")
    connection = oracledb.connect(
        user=username,
        password=password,
        dsn=build_dsn(),
    )
    try:
        yield connection
    finally:
        connection.close()

def fetch_all(
    username: str,
    password: str,
    sql: str,
    binds: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    with oracle_connection(username, password) as connection:
        with connection.cursor() as cursor:
            cursor.execute(sql, binds or {})
            if cursor.description is None:
                return []
            columns = [column[0].lower() for column in cursor.description]
            return [dict(zip(columns, row)) for row in cursor.fetchall()]

def test_connection(username: str, password: str) -> dict[str, Any]:
    rows = fetch_all(
        username,
        password,
        '''
        SELECT
            USER AS database_user,
            SYS_CONTEXT('USERENV', 'DB_NAME') AS database_name,
            SYS_CONTEXT('USERENV', 'INSTANCE_NAME') AS instance_name,
            SYS_CONTEXT('USERENV', 'SERVICE_NAME') AS service_name
        FROM dual
        ''',
    )
    if not rows:
        raise RuntimeError("Oracle connection succeeded, but the identity query returned no rows.")
    return rows[0]
