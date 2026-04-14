package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/jeffdc/grove/ops"
	"github.com/jeffdc/grove/protocol"
	"github.com/jeffdc/grove/supervisor"
)

func main() {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)

	// Send hello message on startup.
	hello := protocol.NewHelloMessage()
	if err := encoder.Encode(hello); err != nil {
		fmt.Fprintf(os.Stderr, "failed to write hello: %v\n", err)
		os.Exit(1)
	}

	// Main loop: read one JSON request per line, dispatch, respond.
	scanner := bufio.NewScanner(os.Stdin)
	// Allow lines up to 10 MB for large batch requests.
	scanner.Buffer(make([]byte, 0, 64*1024), 10*1024*1024)

	for scanner.Scan() {
		line := scanner.Bytes()

		var req protocol.Request
		if err := json.Unmarshal(line, &req); err != nil {
			resp := protocol.ErrorResponseForMalformedInput(string(line))
			_ = encoder.Encode(resp)
			continue
		}

		resp := dispatch(req)
		if err := encoder.Encode(resp); err != nil {
			fmt.Fprintf(os.Stderr, "failed to write response: %v\n", err)
			os.Exit(1)
		}
	}

	if err := scanner.Err(); err != nil && err != io.EOF {
		fmt.Fprintf(os.Stderr, "stdin read error: %v\n", err)
		os.Exit(1)
	}
}

// defaultOpTimeout is the timeout for filesystem operations that could hang
// on a NAS mount. Individual requests can override this via timeout_seconds.
const defaultOpTimeout = 60 * time.Second

// dispatch routes a request to the appropriate handler.
// Filesystem I/O operations are wrapped with supervisor.WithTimeout to prevent
// a hung NAS mount from blocking the worker indefinitely.
func dispatch(req protocol.Request) protocol.Response {
	switch req.Op {
	// These ops have their own timeout handling or are trivial stats.
	case "check_mount":
		return ops.CheckMount(req)
	case "path_exists":
		return ops.PathExists(req)
	case "stat_path":
		return ops.StatPath(req)
	case "stat_paths":
		return ops.StatPaths(req)

	// Filesystem I/O ops — wrapped with timeout isolation.
	case "walk_tree":
		return supervisor.WithTimeout(req, ops.WalkTree, defaultOpTimeout)
	case "hash_path":
		return supervisor.WithTimeout(req, ops.HashPath, defaultOpTimeout)
	case "hash_paths":
		return supervisor.WithTimeout(req, ops.HashPaths, defaultOpTimeout)
	case "copy_and_hash":
		return supervisor.WithTimeout(req, ops.CopyAndHash, defaultOpTimeout)
	case "move_file":
		return supervisor.WithTimeout(req, ops.MoveFile, defaultOpTimeout)
	case "unlink_path":
		return supervisor.WithTimeout(req, ops.UnlinkPath, defaultOpTimeout)
	case "mkdir_all":
		return supervisor.WithTimeout(req, ops.MkdirAll, defaultOpTimeout)
	case "remove_empty_dirs":
		return supervisor.WithTimeout(req, ops.RemoveEmptyDirs, defaultOpTimeout)

	default:
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("unknown op: %q", req.Op))
	}
}
