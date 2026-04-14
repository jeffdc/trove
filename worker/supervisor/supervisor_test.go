package supervisor

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/jeffdc/grove/protocol"
)

func makeRequest(id int64, op string, args any) protocol.Request {
	raw, _ := json.Marshal(args)
	return protocol.Request{ID: id, Op: op, Args: raw}
}

func fastOp(req protocol.Request) protocol.Response {
	return protocol.NewSuccessResponse(req.ID, json.RawMessage(`{"status":"ok"}`))
}

func slowOp(req protocol.Request) protocol.Response {
	time.Sleep(2 * time.Second)
	return protocol.NewSuccessResponse(req.ID, json.RawMessage(`{"status":"ok"}`))
}

func TestWithTimeout_CompletesInTime(t *testing.T) {
	req := makeRequest(1, "test_op", map[string]any{})
	resp := WithTimeout(req, fastOp, 5*time.Second)

	if !resp.OK {
		t.Fatalf("expected success response, got error: %v", resp.Error)
	}
	if resp.ID != 1 {
		t.Fatalf("expected ID 1, got %d", resp.ID)
	}
}

func TestWithTimeout_ExceedsTimeout(t *testing.T) {
	req := makeRequest(2, "test_op", map[string]any{})
	resp := WithTimeout(req, slowOp, 100*time.Millisecond)

	if resp.OK {
		t.Fatal("expected timeout error, got success")
	}
	if resp.Error == nil {
		t.Fatal("expected error detail, got nil")
	}
	if resp.Error.Kind != protocol.ErrTimeout {
		t.Fatalf("expected error kind %q, got %q", protocol.ErrTimeout, resp.Error.Kind)
	}
	if resp.ID != 2 {
		t.Fatalf("expected ID 2, got %d", resp.ID)
	}
}

func TestWithTimeout_UsesArgsTimeout(t *testing.T) {
	// Request specifies timeout_seconds: 1. The fast op should complete well
	// within that. We set a very short default (1ms) to prove the args timeout
	// is used instead of the default.
	req := makeRequest(3, "test_op", map[string]any{"timeout_seconds": 1})
	resp := WithTimeout(req, fastOp, 1*time.Millisecond)

	if !resp.OK {
		t.Fatalf("expected success, got error: %v", resp.Error)
	}
}

func TestWithTimeout_DefaultTimeoutWhenAbsent(t *testing.T) {
	// No timeout_seconds in args. Use a slow op (sleeps 2s) with a short
	// default timeout (100ms). If the default is applied, we get a timeout error.
	req := makeRequest(4, "test_op", map[string]any{})
	resp := WithTimeout(req, slowOp, 100*time.Millisecond)

	if resp.OK {
		t.Fatal("expected timeout error (default should be 100ms), got success")
	}
	if resp.Error.Kind != protocol.ErrTimeout {
		t.Fatalf("expected error kind %q, got %q", protocol.ErrTimeout, resp.Error.Kind)
	}
}

func TestWithTimeout_WorkerStaysAlive(t *testing.T) {
	// First call: times out.
	req1 := makeRequest(5, "test_op", map[string]any{})
	resp1 := WithTimeout(req1, slowOp, 100*time.Millisecond)

	if resp1.OK {
		t.Fatal("first call: expected timeout error, got success")
	}
	if resp1.Error.Kind != protocol.ErrTimeout {
		t.Fatalf("first call: expected error kind %q, got %q", protocol.ErrTimeout, resp1.Error.Kind)
	}

	// Second call: completes successfully, proving the worker is still alive.
	req2 := makeRequest(6, "test_op", map[string]any{})
	resp2 := WithTimeout(req2, fastOp, 5*time.Second)

	if !resp2.OK {
		t.Fatalf("second call: expected success, got error: %v", resp2.Error)
	}
	if resp2.ID != 6 {
		t.Fatalf("second call: expected ID 6, got %d", resp2.ID)
	}
}
