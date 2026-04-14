// Package supervisor provides timeout isolation for filesystem operations.
// The worker process is the isolation boundary; this package wraps individual
// operations so that a hung syscall (e.g. NAS I/O) returns a timeout error
// instead of blocking the dispatch loop forever.
package supervisor

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/jeffdc/grove/protocol"
)

// timeoutArgs is used to extract just the timeout_seconds field from the
// request args without requiring knowledge of the full args struct.
type timeoutArgs struct {
	TimeoutSeconds int `json:"timeout_seconds"`
}

// WithTimeout runs op in a goroutine and waits for either its result or a
// timeout. If the request's args contain a positive timeout_seconds value, that
// is used; otherwise defaultTimeout applies.
//
// If the operation exceeds the timeout, a timeout error response is returned.
// The goroutine running the operation may leak if the underlying syscall is
// stuck in kernel I/O (e.g. a hung NAS mount). This is acceptable because the
// OCaml parent process monitors worker responsiveness and will kill/restart the
// worker process if it becomes completely unresponsive.
func WithTimeout(req protocol.Request, op func(protocol.Request) protocol.Response, defaultTimeout time.Duration) protocol.Response {
	timeout := defaultTimeout

	// Try to extract timeout_seconds from the request args.
	var ta timeoutArgs
	if len(req.Args) > 0 {
		// Ignore errors — if args don't have the field, we use the default.
		_ = json.Unmarshal(req.Args, &ta)
	}
	if ta.TimeoutSeconds > 0 {
		timeout = time.Duration(ta.TimeoutSeconds) * time.Second
	}

	ch := make(chan protocol.Response, 1)
	go func() {
		ch <- op(req)
	}()

	select {
	case resp := <-ch:
		return resp
	case <-time.After(timeout):
		return protocol.NewErrorResponse(req.ID, protocol.ErrTimeout,
			fmt.Sprintf("operation timed out after %s", timeout))
	}
}
