package ops

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/jeffdc/grove/protocol"
)

func TestCheckMount_HealthyPath(t *testing.T) {
	tmpDir := t.TempDir()
	args, _ := json.Marshal(checkMountArgs{Path: tmpDir, TimeoutSeconds: 2})
	req := protocol.Request{ID: 1, Op: "check_mount", Args: args}

	resp := CheckMount(req)

	if !resp.OK {
		t.Fatalf("expected OK response, got error: %+v", resp.Error)
	}

	var result checkMountResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("failed to unmarshal result: %v", err)
	}
	if !result.Available {
		t.Error("expected available=true for existing temp dir")
	}
	if result.Error != "" {
		t.Errorf("expected no error string, got %q", result.Error)
	}
}

func TestCheckMount_NonExistentPath(t *testing.T) {
	args, _ := json.Marshal(checkMountArgs{Path: "/tmp/does-not-exist-" + t.Name(), TimeoutSeconds: 2})
	req := protocol.Request{ID: 2, Op: "check_mount", Args: args}

	// Clean up in case it somehow exists.
	os.RemoveAll("/tmp/does-not-exist-" + t.Name())

	resp := CheckMount(req)

	// Non-existent path is a successful result, not a protocol error.
	if !resp.OK {
		t.Fatalf("expected OK response for non-existent path, got error: %+v", resp.Error)
	}

	var result checkMountResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("failed to unmarshal result: %v", err)
	}
	if result.Available {
		t.Error("expected available=false for non-existent path")
	}
	if result.Error == "" {
		t.Error("expected error string describing the issue")
	}
}

func TestCheckMount_DefaultTimeout(t *testing.T) {
	// When timeout_seconds is omitted (zero value), it should default to 5.
	args := []byte(`{"path": "` + t.TempDir() + `"}`)
	req := protocol.Request{ID: 3, Op: "check_mount", Args: args}

	resp := CheckMount(req)

	if !resp.OK {
		t.Fatalf("expected OK response, got error: %+v", resp.Error)
	}

	var result checkMountResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("failed to unmarshal result: %v", err)
	}
	if !result.Available {
		t.Error("expected available=true for existing temp dir with default timeout")
	}
}

func TestCheckMount_InvalidArgs(t *testing.T) {
	req := protocol.Request{ID: 4, Op: "check_mount", Args: json.RawMessage(`{not valid json`)}

	resp := CheckMount(req)

	if resp.OK {
		t.Fatal("expected error response for invalid JSON args")
	}
	if resp.Error == nil {
		t.Fatal("expected error detail to be set")
	}
	if resp.Error.Kind != protocol.ErrUnknown {
		t.Errorf("expected error kind %q, got %q", protocol.ErrUnknown, resp.Error.Kind)
	}
}
