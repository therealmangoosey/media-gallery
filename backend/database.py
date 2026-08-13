from datetime import datetime, timezone

from sqlalchemy import (
    Column,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    create_engine,
)
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import relationship, sessionmaker

import os

# Store the DB relative to the repo root (not the process CWD) so the app
# works regardless of where it is launched from.
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SQLALCHEMY_DATABASE_URL = f"sqlite:///{os.path.join(BASE_DIR, 'gallery.db')}"

engine = create_engine(
    SQLALCHEMY_DATABASE_URL, connect_args={"check_same_thread": False}
)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

Base = declarative_base()


def utcnow():
    """Timezone-aware 'now' (avoids the deprecated datetime.utcnow)."""
    return datetime.now(timezone.utc)


class Image(Base):
    __tablename__ = "images"

    id = Column(Integer, primary_key=True, index=True)
    uuid = Column(String, unique=True, index=True)
    original_filename = Column(String)
    extension = Column(String)
    status = Column(String, default="pending", index=True)  # pending, approved, quarantined, rejected
    moderation_score = Column(Float, nullable=True)
    moderation_reason = Column(String, nullable=True)
    created_at = Column(DateTime, default=utcnow, index=True)
    reports_count = Column(Integer, default=0)

    reports = relationship("Report", back_populates="image", cascade="all, delete-orphan")


class Report(Base):
    __tablename__ = "reports"

    id = Column(Integer, primary_key=True, index=True)
    image_id = Column(Integer, ForeignKey("images.id"), index=True)
    reason = Column(String)
    details = Column(String, nullable=True)
    created_at = Column(DateTime, default=utcnow)
    ip_hash = Column(String)  # Keyed HMAC of the reporter's IP (not raw IP)

    image = relationship("Image", back_populates="reports")


class AdminAction(Base):
    __tablename__ = "admin_actions"

    id = Column(Integer, primary_key=True, index=True)
    action = Column(String)  # approve, reject, delete, etc.
    image_uuid = Column(String)
    timestamp = Column(DateTime, default=utcnow)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def init_db():
    Base.metadata.create_all(bind=engine)
