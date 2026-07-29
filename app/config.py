from dataclasses import dataclass
from pathlib import Path
import os
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent

env_file = os.getenv("ENV_FILE", ".env.qa")

load_dotenv(BASE_DIR / env_file)

@dataclass(frozen=True)
class Settings:
    app_name: str = os.getenv("APP_NAME", "EagleApps Grading Dashboard")
    app_env: str = os.getenv("APP_ENV", "qa")
    secret_key: str = os.getenv("APP_SECRET_KEY", "development-only-change-me")
    oracle_host: str = os.getenv("ORACLE_HOST", "")
    oracle_port: int = int(os.getenv("ORACLE_PORT", "1521"))
    oracle_sid: str = os.getenv("ORACLE_SID", "")
    oracle_service_name: str = os.getenv("ORACLE_SERVICE_NAME", "")
    oracle_client_dir: str = os.getenv("ORACLE_CLIENT_DIR", "")
    oracle_schema: str = os.getenv("ORACLE_SCHEMA", "KSTRUNK").upper()
    session_ttl_minutes: int = int(os.getenv("SESSION_TTL_MINUTES", "60"))

settings = Settings()
