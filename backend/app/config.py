"""
Configuration Module for HRT Systems Backend.

This module defines system-wide settings loaded from environment variables or .env files.
It controls PostgreSQL connection strings, Temporal workflow endpoints, and security keys.
"""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """System settings for the HRT Systems Modular Monolith."""

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # Application
    APP_NAME: str = "HRT Systems ERP"
    ENVIRONMENT: str = "development"
    DEBUG: bool = True
    PORT: int = 8000

    # PostgreSQL Database Connection
    DATABASE_URL: str = "postgresql://postgres:postgres@localhost:5432/hrt_erp"
    DB_POOL_MIN_SIZE: int = 5
    DB_POOL_MAX_SIZE: int = 20

    # Control Plane & Fleet Management (SDLC_19)
    CONTROL_PLANE_URL: str = "http://localhost:9000"
    CONTROL_PLANE_API_KEY: str = "dev-secret-key"

    # Temporal Workflow Engine (SDLC_15)
    TEMPORAL_HOST: str = "localhost:7233"
    TEMPORAL_NAMESPACE: str = "default"
    TEMPORAL_TASK_QUEUE: str = "hrt-erp-integrations"

    # Default Reporting Currency (SDLC_21 Decision Q3)
    DEFAULT_GROUP_REPORTING_CURRENCY: str = "AUD"


settings = Settings()
