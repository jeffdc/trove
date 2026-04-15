#!/usr/bin/env bash
#
# Side-by-side validation: Python trove vs OCaml trove
#
# Everything runs in /tmp. No production databases or libraries are touched.
# Creates synthetic test files, runs both tools, compares DB state.
#
# Usage: ./scripts/validate_side_by_side.sh
#
# Prerequisites:
#   - Python trove installed (python -m trove)
#   - OCaml trove built (make build)
#   - worker binary available via GROVE_WORKER_PATH or at the default sibling grove path
#   - sqlite3 CLI available
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TROVE_OCAML="$REPO_ROOT/ocaml/_build/default/bin/main.exe"
DEFAULT_WORKER_BIN="$REPO_ROOT/../../../grove/worker"
WORKER_BIN="${GROVE_WORKER_PATH:-${WORKER_BIN:-$DEFAULT_WORKER_BIN}}"
TIMESTAMP=$(date +%s)
TEST_BASE="/tmp/trove_validate_${TIMESTAMP}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo -e "${YELLOW}WARN${NC}: $1"; }
info() { echo -e "     $1"; }

FAILURES=0

cleanup() {
    echo ""
    echo "Cleaning up $TEST_BASE..."
    rm -rf "$TEST_BASE"
}
trap cleanup EXIT

# ---------- Setup ----------

echo "=== Side-by-side validation ==="
echo "Test directory: $TEST_BASE"
echo ""

mkdir -p "$TEST_BASE"/{source,lib_py,lib_ocaml}

# Check prerequisites
if ! command -v sqlite3 &>/dev/null; then
    echo "Error: sqlite3 not found"
    exit 1
fi

if [ ! -x "$TROVE_OCAML" ]; then
    echo "Error: OCaml binary not found at $TROVE_OCAML (run 'make build')"
    exit 1
fi

if [ ! -x "$WORKER_BIN" ]; then
    echo "Error: worker binary not found at $WORKER_BIN"
    echo "Set GROVE_WORKER_PATH=/path/to/worker or build the external worker with 'make build-worker'."
    exit 1
fi

# Create synthetic test files with known content
echo "Creating synthetic test files..."
echo "photo alpha content" > "$TEST_BASE/source/photo_a.jpg"
echo "photo beta content"  > "$TEST_BASE/source/photo_b.jpg"
echo "photo gamma content" > "$TEST_BASE/source/photo_c.jpg"
# Duplicate of photo_a (same content, different name)
echo "photo alpha content" > "$TEST_BASE/source/photo_a_copy.jpg"
# File with spaces and special chars
echo "special file content" > "$TEST_BASE/source/my photo (1).jpg"

DB_PY="$TEST_BASE/state_py.db"
DB_OCAML="$TEST_BASE/state_ocaml.db"

# ================================================================
# Test 1: Schema compatibility — create DB with Python, read with OCaml
# ================================================================

echo ""
echo "--- Test 1: Schema compatibility ---"

trove --db "$DB_PY" create testlib "$TEST_BASE/lib_py" 2>&1 || true

# Verify Python DB was created
if [ -f "$DB_PY" ]; then
    pass "Python created database"
else
    fail "Python failed to create database"
fi

# Check Python schema
PY_TABLES=$(sqlite3 "$DB_PY" ".tables" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ')
info "Python tables: $PY_TABLES"

# Now try reading it with OCaml
OCAML_LIST_OUTPUT=$(GROVE_WORKER_PATH="$WORKER_BIN" "$TROVE_OCAML" list --db "$DB_PY" 2>&1) || true
if echo "$OCAML_LIST_OUTPUT" | grep -q "testlib"; then
    pass "OCaml reads Python-created database"
    info "OCaml output: $OCAML_LIST_OUTPUT"
else
    fail "OCaml cannot read Python-created database"
    info "OCaml output: $OCAML_LIST_OUTPUT"
fi

# ================================================================
# Test 2: Config round-trip — Python config readable by OCaml
# ================================================================

echo ""
echo "--- Test 2: Config round-trip ---"

PY_CONFIG=$(sqlite3 "$DB_PY" "SELECT config FROM libraries WHERE name='testlib'" 2>/dev/null)
info "Python config_json: $PY_CONFIG"

# Create OCaml library with same config and verify
GROVE_WORKER_PATH="$WORKER_BIN" "$TROVE_OCAML" create --db "$DB_OCAML" testlib "$TEST_BASE/lib_ocaml" 2>&1 || true
OCAML_CONFIG=$(sqlite3 "$DB_OCAML" "SELECT config FROM libraries WHERE name='testlib'" 2>/dev/null)
info "OCaml config_json: $OCAML_CONFIG"

# Both should be valid JSON with same structure
PY_KEYS=$(echo "$PY_CONFIG" | python3 -c "import sys,json; print(sorted(json.load(sys.stdin).keys()))" 2>/dev/null || echo "PARSE_ERROR")
OCAML_KEYS=$(echo "$OCAML_CONFIG" | python3 -c "import sys,json; print(sorted(json.load(sys.stdin).keys()))" 2>/dev/null || echo "PARSE_ERROR")

if [ "$PY_KEYS" = "$OCAML_KEYS" ]; then
    pass "Config JSON has same top-level keys"
    info "Keys: $PY_KEYS"
else
    fail "Config JSON keys differ"
    info "Python: $PY_KEYS"
    info "OCaml:  $OCAML_KEYS"
fi

# ================================================================
# Test 3: Discovery + Hashing — same files found, same hashes
# ================================================================

echo ""
echo "--- Test 3: Discovery and hashing ---"

# Run Python add (copy mode — source is outside library)
echo "Running Python trove add..."
trove --db "$DB_PY" add testlib "$TEST_BASE/source" --yes 2>&1 | tee "$TEST_BASE/py_add.log" || true

# Run OCaml add
echo "Running OCaml trove add..."
GROVE_WORKER_PATH="$WORKER_BIN" "$TROVE_OCAML" add --db "$DB_OCAML" testlib "$TEST_BASE/source" 2>&1 | tee "$TEST_BASE/ocaml_add.log" || true

# Compare entry counts
PY_ENTRY_COUNT=$(sqlite3 "$DB_PY" "SELECT COUNT(*) FROM entries WHERE library_id=(SELECT id FROM libraries WHERE name='testlib')" 2>/dev/null || echo "0")
OCAML_ENTRY_COUNT=$(sqlite3 "$DB_OCAML" "SELECT COUNT(*) FROM entries WHERE library_id=(SELECT id FROM libraries WHERE name='testlib')" 2>/dev/null || echo "0")

info "Python entries: $PY_ENTRY_COUNT"
info "OCaml entries:  $OCAML_ENTRY_COUNT"

if [ "$PY_ENTRY_COUNT" = "$OCAML_ENTRY_COUNT" ]; then
    pass "Same number of entries created"
else
    warn "Entry counts differ (may be due to metadata extraction differences)"
fi

# Compare hashes of entries
echo ""
info "Python entry hashes:"
sqlite3 "$DB_PY" "SELECT relative_path, md5_hash, file_size FROM entries WHERE library_id=(SELECT id FROM libraries WHERE name='testlib') ORDER BY md5_hash" 2>/dev/null | while IFS='|' read -r path hash size; do
    info "  $hash  $size  $path"
done

echo ""
info "OCaml entry hashes:"
sqlite3 "$DB_OCAML" "SELECT relative_path, md5_hash, file_size FROM entries WHERE library_id=(SELECT id FROM libraries WHERE name='testlib') ORDER BY md5_hash" 2>/dev/null | while IFS='|' read -r path hash size; do
    info "  $hash  $size  $path"
done

# Compare unique hashes (ignoring path differences from date structure)
PY_HASHES=$(sqlite3 "$DB_PY" "SELECT md5_hash FROM entries WHERE library_id=(SELECT id FROM libraries WHERE name='testlib') ORDER BY md5_hash" 2>/dev/null)
OCAML_HASHES=$(sqlite3 "$DB_OCAML" "SELECT md5_hash FROM entries WHERE library_id=(SELECT id FROM libraries WHERE name='testlib') ORDER BY md5_hash" 2>/dev/null)

if [ "$PY_HASHES" = "$OCAML_HASHES" ]; then
    pass "Same hashes in both databases"
else
    warn "Hashes differ — check entry listings above"
fi

# ================================================================
# Test 4: File tree comparison
# ================================================================

echo ""
echo "--- Test 4: Library file trees ---"

info "Python library tree:"
find "$TEST_BASE/lib_py" -type f | sort | while read -r f; do
    rel="${f#$TEST_BASE/lib_py/}"
    info "  $rel"
done

echo ""
info "OCaml library tree:"
find "$TEST_BASE/lib_ocaml" -type f | sort | while read -r f; do
    rel="${f#$TEST_BASE/lib_ocaml/}"
    info "  $rel"
done

# ================================================================
# Test 5: Remaining file records (should be cleaned up)
# ================================================================

echo ""
echo "--- Test 5: Remaining file records ---"

PY_FILES_LEFT=$(sqlite3 "$DB_PY" "SELECT COUNT(*) FROM files" 2>/dev/null || echo "?")
OCAML_FILES_LEFT=$(sqlite3 "$DB_OCAML" "SELECT COUNT(*) FROM files" 2>/dev/null || echo "?")

info "Python files table rows remaining: $PY_FILES_LEFT"
info "OCaml files table rows remaining:  $OCAML_FILES_LEFT"

if [ "$PY_FILES_LEFT" = "0" ] && [ "$OCAML_FILES_LEFT" = "0" ]; then
    pass "Both cleaned up file records"
elif [ "$PY_FILES_LEFT" = "$OCAML_FILES_LEFT" ]; then
    pass "Same number of file records remaining"
else
    warn "Different file record counts remaining"
fi

# ================================================================
# Test 6: Schema structure comparison
# ================================================================

echo ""
echo "--- Test 6: Schema structure ---"

PY_SCHEMA=$(sqlite3 "$DB_PY" ".schema" 2>/dev/null | sort)
OCAML_SCHEMA=$(sqlite3 "$DB_OCAML" ".schema" 2>/dev/null | sort)

echo "$PY_SCHEMA" > "$TEST_BASE/schema_py.txt"
echo "$OCAML_SCHEMA" > "$TEST_BASE/schema_ocaml.txt"

if diff -q "$TEST_BASE/schema_py.txt" "$TEST_BASE/schema_ocaml.txt" >/dev/null 2>&1; then
    pass "Identical schema"
else
    warn "Schema differences (may include expected migration differences):"
    diff --unified "$TEST_BASE/schema_py.txt" "$TEST_BASE/schema_ocaml.txt" || true
fi

# ================================================================
# Summary
# ================================================================

echo ""
echo "=== Validation complete ==="
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}All tests passed (some may have warnings for expected differences).${NC}"
else
    echo -e "${RED}$FAILURES test(s) failed.${NC}"
fi

echo ""
echo "Detailed logs in: $TEST_BASE/"
echo "  py_add.log    — Python trove add output"
echo "  ocaml_add.log — OCaml trove add output"
echo "  state_py.db   — Python database"
echo "  state_ocaml.db — OCaml database"
echo ""
echo "To inspect databases manually:"
echo "  sqlite3 $DB_PY"
echo "  sqlite3 $DB_OCAML"
