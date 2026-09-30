import os
from pathlib import Path
from typing import Generator
from dotenv import load_dotenv
from sqlalchemy import create_engine, text
from sqlalchemy.orm import declarative_base, sessionmaker, Session

# Base class for SQLAlchemy ORM models
Base = declarative_base()

def _load_env_file():
    """Load agent/.env or .env if present without overriding existing runtime vars."""
    candidates = [
        Path.cwd() / "agent" / ".env",
        Path.cwd() / ".env",
        Path(__file__).resolve().parent.parent / ".env",
        Path(__file__).resolve().parent.parent.parent / ".env",
    ]
    for candidate in candidates:
        if candidate.is_file():
            load_dotenv(candidate, override=False)
            break

_load_env_file()

def get_database_url() -> str:
    """Retrieve DATABASE_URL from environment with Supabase / Render compatibility."""
    _load_env_file()
    url = os.getenv("DATABASE_URL")
    if not url:
        # Local development fallback
        return "sqlite:///./dont_miss_local.db"
    
    # Render and Supabase compatibility: ensure psycopg2 driver is used with SQLAlchemy 2.0+
    if url.startswith("postgres://"):
        url = url.replace("postgres://", "postgresql+psycopg2://", 1)
    elif url.startswith("postgresql://"):
        url = url.replace("postgresql://", "postgresql+psycopg2://", 1)
    return url

_engine = None
_SessionLocal = None

def get_db_engine():
    global _engine
    if _engine is None:
        db_url = get_database_url()
        connect_args = {}
        engine_kwargs = {
            "pool_pre_ping": True,
        }
        if db_url.startswith("sqlite"):
            connect_args["check_same_thread"] = False
        else:
            # Production settings for Supabase PostgreSQL
            engine_kwargs["pool_size"] = 5
            engine_kwargs["max_overflow"] = 10
            engine_kwargs["pool_recycle"] = 300

        _engine = create_engine(
            db_url,
            connect_args=connect_args,
            **engine_kwargs,
        )
    return _engine

def get_session_factory():
    global _SessionLocal
    if _SessionLocal is None:
        engine = get_db_engine()
        _SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    return _SessionLocal

def get_db_session() -> Generator[Session, None, None]:
    """Dependency generator for FastAPI routes."""
    session_factory = get_session_factory()
    session = session_factory()
    try:
        yield session
    finally:
        session.close()

def init_db():
    """Create all tables if they do not exist."""
    engine = get_db_engine()
    Base.metadata.create_all(bind=engine)

def check_db_connectivity() -> bool:
    """Perform a lightweight health check against the configured database."""
    try:
        engine = get_db_engine()
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return True
    except Exception:
        return False
