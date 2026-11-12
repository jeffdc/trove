import pytest

from trove.db import StateDB


@pytest.fixture
def db(tmp_path):
    """Create a StateDB in a temp directory for testing."""
    db_path = tmp_path / "test_state.db"
    with StateDB(db_path) as state_db:
        yield state_db


@pytest.fixture
def library(db, tmp_path):
    """Create a test library with a real temp directory as location."""
    lib_dir = tmp_path / "library"
    lib_dir.mkdir()
    return db.create_library("TestLibrary", str(lib_dir))
