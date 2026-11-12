.PHONY: help test check format fix lint build install clean all ci done-checks

help:
	@echo "Available targets:"
	@echo "  test      - Run pytest test suite"
	@echo "  check     - Run ruff and mypy checks"
	@echo "  format    - Format code with ruff"
	@echo "  fix       - Auto-fix ruff issues"
	@echo "  lint      - Alias for 'check'"
	@echo "  build     - Build the package"
	@echo "  install   - Install package in editable mode with dev dependencies"
	@echo "  clean     - Remove build artifacts"
	@echo "  all       - Run format, check, and test"
	@echo "  ci        - Run full CI pipeline (check + test)"
	@echo "  done-checks - Hard checks run by mull done (check + test)"

test:
	python -m pytest tests/ -v

check:
	ruff check src tests
	mypy src/trove

format:
	ruff format src tests

fix:
	ruff check src tests --fix

lint: check

build:
	python -m build

install:
	pip install -e ".[dev]"

clean:
	rm -rf build/ dist/ *.egg-info .pytest_cache .mypy_cache
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true

all: format check test

ci: check test

done-checks: check test
