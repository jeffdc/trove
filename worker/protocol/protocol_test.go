package protocol

import (
	"encoding/json"
	"testing"
)

func TestRequestEncodeDecode(t *testing.T) {
	args := json.RawMessage(`{"path":"/Volumes/nas","timeout_seconds":5}`)
	req := Request{
		ID:   42,
		Op:   "check_mount",
		Args: args,
	}

	data, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded Request
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.ID != 42 {
		t.Errorf("id: got %d, want 42", decoded.ID)
	}
	if decoded.Op != "check_mount" {
		t.Errorf("op: got %q, want %q", decoded.Op, "check_mount")
	}
	if string(decoded.Args) != string(args) {
		t.Errorf("args: got %s, want %s", decoded.Args, args)
	}

	// Verify JSON field names are snake_case
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("unmarshal raw: %v", err)
	}
	for _, key := range []string{"id", "op", "args"} {
		if _, ok := raw[key]; !ok {
			t.Errorf("expected JSON key %q", key)
		}
	}
}

func TestSuccessResponseEncodeDecode(t *testing.T) {
	result := json.RawMessage(`{"available":true}`)
	resp := Response{
		ID:     42,
		OK:     true,
		Result: result,
	}

	data, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded Response
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.ID != 42 {
		t.Errorf("id: got %d, want 42", decoded.ID)
	}
	if !decoded.OK {
		t.Error("ok: got false, want true")
	}
	if string(decoded.Result) != string(result) {
		t.Errorf("result: got %s, want %s", decoded.Result, result)
	}
	if decoded.Error != nil {
		t.Errorf("error: got %v, want nil", decoded.Error)
	}

	// Verify JSON structure: error field should be absent on success
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("unmarshal raw: %v", err)
	}
	if _, ok := raw["error"]; ok {
		t.Error("success response should not have error field")
	}
}

func TestErrorResponseEncodeDecode(t *testing.T) {
	resp := Response{
		ID: 42,
		OK: false,
		Error: &ErrorDetail{
			Kind:    ErrTimeout,
			Message: "operation timed out after 5s",
		},
	}

	data, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded Response
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.ID != 42 {
		t.Errorf("id: got %d, want 42", decoded.ID)
	}
	if decoded.OK {
		t.Error("ok: got true, want false")
	}
	if decoded.Error == nil {
		t.Fatal("error: got nil, want error detail")
	}
	if decoded.Error.Kind != ErrTimeout {
		t.Errorf("error.kind: got %q, want %q", decoded.Error.Kind, ErrTimeout)
	}
	if decoded.Error.Message != "operation timed out after 5s" {
		t.Errorf("error.message: got %q", decoded.Error.Message)
	}

	// Verify JSON structure: result field should be absent on error
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("unmarshal raw: %v", err)
	}
	if _, ok := raw["result"]; ok {
		t.Error("error response should not have result field")
	}
}

func TestErrorKindValues(t *testing.T) {
	expected := map[ErrorKind]string{
		ErrTimeout:          "timeout",
		ErrNotFound:         "not_found",
		ErrPermissionDenied: "permission_denied",
		ErrCrossDevice:      "cross_device",
		ErrAlreadyExists:    "already_exists",
		ErrIO:               "io_error",
		ErrWorkerCrash:      "worker_crash",
		ErrUnknown:          "unknown",
	}

	for kind, want := range expected {
		if string(kind) != want {
			t.Errorf("ErrorKind: got %q, want %q", kind, want)
		}
	}

	if len(expected) != 8 {
		t.Errorf("expected 8 error kinds, got %d", len(expected))
	}
}

func TestHelloMessage(t *testing.T) {
	hello := NewHelloMessage()

	if hello.ProtocolVersion != 1 {
		t.Errorf("protocol_version: got %d, want 1", hello.ProtocolVersion)
	}
	if hello.WorkerVersion != "0.1.0" {
		t.Errorf("worker_version: got %q, want %q", hello.WorkerVersion, "0.1.0")
	}

	expectedCaps := []string{
		"check_mount", "path_exists", "stat_path", "stat_paths",
		"walk_tree", "hash_path", "hash_paths", "copy_and_hash",
		"move_file", "unlink_path", "mkdir_all", "remove_empty_dirs",
	}
	if len(hello.Capabilities) != len(expectedCaps) {
		t.Fatalf("capabilities: got %d, want %d", len(hello.Capabilities), len(expectedCaps))
	}
	for i, cap := range expectedCaps {
		if hello.Capabilities[i] != cap {
			t.Errorf("capabilities[%d]: got %q, want %q", i, hello.Capabilities[i], cap)
		}
	}

	// Verify JSON field names
	data, err := json.Marshal(hello)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	for _, key := range []string{"protocol_version", "worker_version", "capabilities"} {
		if _, ok := raw[key]; !ok {
			t.Errorf("expected JSON key %q", key)
		}
	}
}

func TestDecodeUnknownOp(t *testing.T) {
	input := `{"id":99,"op":"frobnicate","args":{"x":1}}`

	var req Request
	if err := json.Unmarshal([]byte(input), &req); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if req.ID != 99 {
		t.Errorf("id: got %d, want 99", req.ID)
	}
	if req.Op != "frobnicate" {
		t.Errorf("op: got %q, want %q", req.Op, "frobnicate")
	}
	// Unknown ops parse fine — dispatch handles the error, not decode
}

func TestDecodeMalformedJSON(t *testing.T) {
	input := `{not valid json`

	resp := ErrorResponseForMalformedInput(input)

	if resp.ID != -1 {
		t.Errorf("id: got %d, want -1", resp.ID)
	}
	if resp.OK {
		t.Error("ok: got true, want false")
	}
	if resp.Error == nil {
		t.Fatal("error: got nil")
	}
	if resp.Error.Kind != ErrUnknown {
		t.Errorf("error.kind: got %q, want %q", resp.Error.Kind, ErrUnknown)
	}
	if resp.Error.Message == "" {
		t.Error("error.message: should not be empty")
	}
}
