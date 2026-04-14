WORKER_DIR   := worker
OCAML_DIR    := ocaml
WORKER_BIN   := $(WORKER_DIR)/worker
TROVE_BIN    := $(OCAML_DIR)/_build/default/bin/main.exe

.PHONY: help build build-worker build-ocaml test test-worker test-ocaml clean

help:
	@echo "Available targets:"
	@echo "  build          - Build Go worker and OCaml binary"
	@echo "  build-worker   - Build Go worker only"
	@echo "  build-ocaml    - Build OCaml binary only"
	@echo "  test           - Run all tests (Go + OCaml)"
	@echo "  test-worker    - Run Go worker tests"
	@echo "  test-ocaml     - Run OCaml tests"
	@echo "  clean          - Remove build artifacts"

build: build-worker build-ocaml

build-worker:
	cd $(WORKER_DIR) && go build -o worker ./cmd/worker

build-ocaml:
	cd $(OCAML_DIR) && opam exec --switch=5.3.0 -- dune build

test: test-worker test-ocaml

test-worker:
	cd $(WORKER_DIR) && go test ./...

test-ocaml: build-worker
	cd $(OCAML_DIR) && opam exec --switch=5.3.0 -- dune test --force

clean:
	rm -f $(WORKER_BIN)
	cd $(OCAML_DIR) && opam exec --switch=5.3.0 -- dune clean
