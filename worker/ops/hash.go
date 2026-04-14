package ops

import (
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/jeffdc/grove/protocol"
)

// ---------- hash_path ----------

type hashPathArgs struct {
	Path string `json:"path"`
}

type hashResult struct {
	Path string `json:"path"`
	MD5  string `json:"md5"`
}

// hashOne opens a file and computes its MD5 by streaming through io.Copy.
func hashOne(path string) (*hashResult, *protocol.ErrorDetail) {
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, &protocol.ErrorDetail{
				Kind:    protocol.ErrNotFound,
				Message: err.Error(),
			}
		}
		if errors.Is(err, os.ErrPermission) {
			return nil, &protocol.ErrorDetail{
				Kind:    protocol.ErrPermissionDenied,
				Message: err.Error(),
			}
		}
		return nil, &protocol.ErrorDetail{
			Kind:    protocol.ErrIO,
			Message: err.Error(),
		}
	}
	defer f.Close()

	h := md5.New()
	if _, err := io.Copy(h, f); err != nil {
		return nil, &protocol.ErrorDetail{
			Kind:    protocol.ErrIO,
			Message: fmt.Sprintf("reading %s: %v", path, err),
		}
	}

	return &hashResult{
		Path: path,
		MD5:  hex.EncodeToString(h.Sum(nil)),
	}, nil
}

// HashPath computes the MD5 hash of a single file by streaming its contents.
func HashPath(req protocol.Request) protocol.Response {
	var args hashPathArgs
	if err := json.Unmarshal(req.Args, &args); err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("invalid args: %v", err))
	}

	result, errDetail := hashOne(args.Path)
	if errDetail != nil {
		return protocol.NewErrorResponse(req.ID, errDetail.Kind, errDetail.Message)
	}

	raw, err := json.Marshal(result)
	if err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("marshal result: %v", err))
	}
	return protocol.NewSuccessResponse(req.ID, raw)
}

// ---------- hash_paths (batch) ----------

type hashPathsArgs struct {
	Paths []string `json:"paths"`
}

type hashPathError struct {
	Path  string               `json:"path"`
	Error protocol.ErrorDetail `json:"error"`
}

type hashPathsResult struct {
	Results []hashResult    `json:"results"`
	Errors  []hashPathError `json:"errors"`
}

// HashPaths computes MD5 hashes for multiple files in a batch. Individual
// failures go into the errors array rather than failing the entire request.
func HashPaths(req protocol.Request) protocol.Response {
	var args hashPathsArgs
	if err := json.Unmarshal(req.Args, &args); err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("invalid args: %v", err))
	}

	result := hashPathsResult{
		Results: []hashResult{},
		Errors:  []hashPathError{},
	}

	for _, path := range args.Paths {
		hr, errDetail := hashOne(path)
		if errDetail != nil {
			result.Errors = append(result.Errors, hashPathError{
				Path:  path,
				Error: *errDetail,
			})
		} else {
			result.Results = append(result.Results, *hr)
		}
	}

	raw, err := json.Marshal(result)
	if err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("marshal result: %v", err))
	}
	return protocol.NewSuccessResponse(req.ID, raw)
}
