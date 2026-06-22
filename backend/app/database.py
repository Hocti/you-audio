import os

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql+asyncpg://ytaudio:ytaudio@db:5432/ytaudio",
)

if "sqlite" in DATABASE_URL:
    # SQLite 不支援連線池參數，必須將其移除
    engine = create_async_engine(DATABASE_URL, echo=False)
else:
    # PostgreSQL 則保留原本的優化參數
    engine = create_async_engine(DATABASE_URL, echo=False, pool_size=5, max_overflow=10)

async_session = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


async def get_session() -> AsyncSession:  # type: ignore[misc]
    async with async_session() as session:
        yield session
