package ops

import (
	"encoding/json"
	"os"
	"time"

	"github.com/jeffdc/grove/protocol"
)

const defaultTimeoutSeconds = 5

type checkMountArgs struct {
	Path           string `json:"path"`
	TimeoutSeconds int    `json:"timeout_seconds"`
}

type checkMountResult struct {
	Available bool   `json:"available"`
	Error     string `json:"error,omitempty"`
}

// CheckMount performs a timed os.Stat on a path to determine if a mount is
// available. If the stat completes within the timeout, it returns a result
// indicating availability. If the path doesn't exist, it returns available=false
// as a normal result (not a protocol error). If the stat times out (e.g. a hung
// NAS mount), it returns a protocol error with kind "timeout".
func CheckMount(req protocol.Request) protocol.Response {
	var args checkMountArgs
	if err := json.Unmarshal(req.Args, &args); err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			"invalid check_mount args: "+err.Error())
	}

	timeout := args.TimeoutSeconds
	if timeout <= 0 {
		timeout = defaultTimeoutSeconds
	}

	type statResult struct {
		err error
	}

	ch := make(chan statResult, 1)

	// NOTE: If the stat times out (e.g. on a hung NAS mount), this goroutine
	// will leak until the OS-level stat call eventually returns or the process
	// exits. This is acceptable — we cannot cancel a blocking syscall.
	go func() {
		_, err := os.Stat(args.Path)
		ch <- statResult{err: err}
	}()

	select {
	case result := <-ch:
		if result.err != nil {
			if os.IsNotExist(result.err) {
				return marshalResult(req.ID, checkMountResult{
					Available: false,
					Error:     "not found",
				})
			}
			return marshalResult(req.ID, checkMountResult{
				Available: false,
				Error:     result.err.Error(),
			})
		}
		return marshalResult(req.ID, checkMountResult{Available: true})

	case <-time.After(time.Duration(timeout) * time.Second):
		return protocol.NewErrorResponse(req.ID, protocol.ErrTimeout,
			"stat timed out after "+time.Duration(time.Duration(timeout)*time.Second).String())
	}
}

func marshalResult(id int64, result checkMountResult) protocol.Response {
	data, err := json.Marshal(result)
	if err != nil {
		return protocol.NewErrorResponse(id, protocol.ErrUnknown,
			"failed to marshal result: "+err.Error())
	}
	return protocol.NewSuccessResponse(id, data)
}
