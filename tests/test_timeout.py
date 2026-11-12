from __future__ import annotations

import time

import pytest

from trove.timeout import run_with_timeout


class TestRunWithTimeout:
    def test_returns_child_result(self):
        """Completed operations return their result."""
        assert run_with_timeout(time.sleep, 0, timeout=1) is None

    def test_raises_timeout_error(self):
        """Long-running operations raise TimeoutError."""
        with pytest.raises(TimeoutError, match="timed out"):
            run_with_timeout(time.sleep, 0.2, timeout=0.01)
