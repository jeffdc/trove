package protocol

import (
	"encoding/json"
	"fmt"
)

// ErrorKind represents the category of error that occurred.
type ErrorKind string

const (
	ErrTimeout          ErrorKind = "timeout"
	ErrNotFound         ErrorKind = "not_found"
	ErrPermissionDenied ErrorKind = "permission_denied"
	ErrCrossDevice      ErrorKind = "cross_device"
	ErrAlreadyExists    ErrorKind = "already_exists"
	ErrIO               ErrorKind = "io_error"
	ErrWorkerCrash      ErrorKind = "worker_crash"
	ErrUnknown          ErrorKind = "unknown"
)

// Request is a single operation request from the parent process.
type Request struct {
	ID   int64            `json:"id"`
	Op   string           `json:"op"`
	Args json.RawMessage  `json:"args"`
}

// ErrorDetail carries structured error information in a response.
type ErrorDetail struct {
	Kind    ErrorKind `json:"kind"`
	Message string    `json:"message"`
}

// Response is a single operation result sent back to the parent process.
type Response struct {
	ID     int64            `json:"id"`
	OK     bool             `json:"ok"`
	Result json.RawMessage  `json:"result,omitempty"`
	Error  *ErrorDetail     `json:"error,omitempty"`
}

// HelloMessage is sent on startup before the main loop begins.
type HelloMessage struct {
	ProtocolVersion int      `json:"protocol_version"`
	WorkerVersion   string   `json:"worker_version"`
	Capabilities    []string `json:"capabilities"`
}

// NewHelloMessage returns a HelloMessage with the current protocol and worker versions.
func NewHelloMessage() HelloMessage {
	return HelloMessage{
		ProtocolVersion: 1,
		WorkerVersion:   "0.1.0",
		Capabilities: []string{
			"check_mount",
			"path_exists",
			"stat_path",
			"stat_paths",
			"walk_tree",
			"hash_path",
			"hash_paths",
			"copy_and_hash",
			"move_file",
			"unlink_path",
			"mkdir_all",
			"remove_empty_dirs",
		},
	}
}

// NewErrorResponse builds an error Response for a given request ID.
func NewErrorResponse(id int64, kind ErrorKind, message string) Response {
	return Response{
		ID: id,
		OK: false,
		Error: &ErrorDetail{
			Kind:    kind,
			Message: message,
		},
	}
}

// NewSuccessResponse builds a success Response for a given request ID.
func NewSuccessResponse(id int64, result json.RawMessage) Response {
	return Response{
		ID:     id,
		OK:     true,
		Result: result,
	}
}

// ErrorResponseForMalformedInput returns a structured error for unparseable JSON.
func ErrorResponseForMalformedInput(input string) Response {
	return NewErrorResponse(-1, ErrUnknown, fmt.Sprintf("malformed JSON: %s", input))
}
