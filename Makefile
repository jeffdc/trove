GROVE_DIR    ?= ../../../grove
OCAML_DIR    ?= ocaml
WORKER_BIN   ?= $(GROVE_DIR)/worker
TROVE_BIN    := $(OCAML_DIR)/_build/default/bin/main.exe

.PHONY: help build build-worker build-ocaml test test-worker test-ocaml clean

help:
	@echo "Available targets:"
	@echo "  build          - Build OCaml binary"
	@echo "  build-worker   - Build external grove worker"
	@echo "  build-ocaml    - Build OCaml binary only"
	@echo "  test           - Run trove tests"
	@echo "  test-worker    - Run external grove worker tests"
	@echo "  test-ocaml     - Run OCaml tests with GROVE_WORKER_PATH=$(abspath $(WORKER_BIN))"
	@echo "  clean          - Remove build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  GROVE_DIR      - Path to the grove worker repo"
	@echo "  WORKER_BIN     - Path to worker binary for OCaml tests and scripts"

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

clean:
	cd $(OCAML_DIR) && opam exec --switch=5.3.0 -- dune clean
