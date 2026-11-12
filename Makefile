GROVE_DIR    ?= ../../../grove
OCAML_DIR    ?= ocaml
WORKER_BIN   ?= $(GROVE_DIR)/worker
TROVE_BIN    := $(OCAML_DIR)/_build/default/bin/main.exe

.PHONY: help build build-worker build-ocaml test test-worker test-ocaml \
	list-db add-db init-db status-db verify-db clean

OCAML_RUN    = cd $(OCAML_DIR) && GROVE_WORKER_PATH="$(abspath $(WORKER_BIN))" opam exec --switch=5.3.0 -- dune exec ./bin/main.exe --

help:
	@echo "Available targets:"
	@echo "  ./trove ...    - Repo-local OCaml CLI launcher"
	@echo "  build          - Build OCaml binary"
	@echo "  build-worker   - Build external grove worker"
	@echo "  build-ocaml    - Build OCaml binary only"
	@echo "  test           - Run trove tests"
	@echo "  test-worker    - Run external grove worker tests"
	@echo "  test-ocaml     - Run OCaml tests with GROVE_WORKER_PATH=$(abspath $(WORKER_BIN))"
	@echo "  list-db        - List libraries from a schema DB (set DB=...)"
	@echo "  add-db         - Import into a library in a schema DB (set DB=... LIB=... SOURCE=...)"
	@echo "  init-db        - Initialize unmanaged files under a library root in a schema DB (set DB=... LIB=...)"
	@echo "  status-db      - Show library status from a schema DB (set DB=... LIB=...)"
	@echo "  verify-db      - Verify library placements on disk from a schema DB (set DB=... LIB=...)"
	@echo "  clean          - Remove build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  GROVE_DIR      - Path to the grove worker repo"
	@echo "  WORKER_BIN     - Path to worker binary for OCaml tests and scripts"
	@echo "  DB             - Path to the schema DB for *-db commands"
	@echo "  LIB            - Library name for add-db/init-db/status-db/verify-db"
	@echo "  SOURCE         - Source directory for add-db"
	@echo "  MAX_ISSUES     - Max issue lines for verify-db (default 50)"

build: build-ocaml

build-worker:
	@test -d "$(GROVE_DIR)" || (echo "Error: grove repo not found at $(GROVE_DIR). Set GROVE_DIR=/path/to/grove." && exit 1)
	$(MAKE) -C "$(GROVE_DIR)" build

build-ocaml:
	cd $(OCAML_DIR) && opam exec --switch=5.3.0 -- dune build

test: test-ocaml

test-worker:
	@test -d "$(GROVE_DIR)" || (echo "Error: grove repo not found at $(GROVE_DIR). Set GROVE_DIR=/path/to/grove." && exit 1)
	$(MAKE) -C "$(GROVE_DIR)" test

test-ocaml:
	@test -x "$(WORKER_BIN)" || (echo "Error: worker binary not found at $(WORKER_BIN). Build it with 'make build-worker GROVE_DIR=/path/to/grove' or set WORKER_BIN=/path/to/grove/worker." && exit 1)
	cd $(OCAML_DIR) && GROVE_WORKER_PATH="$(abspath $(WORKER_BIN))" opam exec --switch=5.3.0 -- dune test --force

list-db:
	@test -n "$(DB)" || (echo "Error: set DB=/path/to/migrated.db" && exit 1)
	@test -x "$(WORKER_BIN)" || (echo "Error: worker binary not found at $(WORKER_BIN). Build it with 'make build-worker GROVE_DIR=/path/to/grove' or set WORKER_BIN=/path/to/grove/worker." && exit 1)
	$(OCAML_RUN) list --db "$(DB)"

add-db:
	@test -n "$(DB)" || (echo "Error: set DB=/path/to/migrated.db" && exit 1)
	@test -n "$(LIB)" || (echo "Error: set LIB='Library Name'" && exit 1)
	@test -n "$(SOURCE)" || (echo "Error: set SOURCE=/path/to/source" && exit 1)
	@test -x "$(WORKER_BIN)" || (echo "Error: worker binary not found at $(WORKER_BIN). Build it with 'make build-worker GROVE_DIR=/path/to/grove' or set WORKER_BIN=/path/to/grove/worker." && exit 1)
	$(OCAML_RUN) add "$(LIB)" "$(SOURCE)" --db "$(DB)"

init-db:
	@test -n "$(DB)" || (echo "Error: set DB=/path/to/migrated.db" && exit 1)
	@test -n "$(LIB)" || (echo "Error: set LIB='Library Name'" && exit 1)
	@test -x "$(WORKER_BIN)" || (echo "Error: worker binary not found at $(WORKER_BIN). Build it with 'make build-worker GROVE_DIR=/path/to/grove' or set WORKER_BIN=/path/to/grove/worker." && exit 1)
	$(OCAML_RUN) init "$(LIB)" --db "$(DB)"

status-db:
	@test -n "$(DB)" || (echo "Error: set DB=/path/to/migrated.db" && exit 1)
	@test -n "$(LIB)" || (echo "Error: set LIB='Library Name'" && exit 1)
	@test -x "$(WORKER_BIN)" || (echo "Error: worker binary not found at $(WORKER_BIN). Build it with 'make build-worker GROVE_DIR=/path/to/grove' or set WORKER_BIN=/path/to/grove/worker." && exit 1)
	$(OCAML_RUN) status "$(LIB)" --db "$(DB)"

verify-db:
	@test -n "$(DB)" || (echo "Error: set DB=/path/to/migrated.db" && exit 1)
	@test -n "$(LIB)" || (echo "Error: set LIB='Library Name'" && exit 1)
	@test -x "$(WORKER_BIN)" || (echo "Error: worker binary not found at $(WORKER_BIN). Build it with 'make build-worker GROVE_DIR=/path/to/grove' or set WORKER_BIN=/path/to/grove/worker." && exit 1)
	$(OCAML_RUN) verify "$(LIB)" --db "$(DB)" $(if $(MAX_ISSUES),--max-issues "$(MAX_ISSUES)",)

clean:
	cd $(OCAML_DIR) && opam exec --switch=5.3.0 -- dune clean
