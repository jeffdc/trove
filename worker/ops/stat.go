package ops

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/jeffdc/grove/protocol"
)

// ---------- path_exists ----------

type pathExistsArgs struct {
	Path string `json:"path"`
}

type pathExistsResult struct {
	Exists bool `json:"exists"`
}

// PathExists checks whether the given path exists on disk.
// Non-existence is a normal result (exists=false), not an error.
func PathExists(req protocol.Request) protocol.Response {
	var args pathExistsArgs
	if err := json.Unmarshal(req.Args, &args); err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("invalid args: %v", err))
	}

	_, err := os.Lstat(args.Path)
	exists := true
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			exists = false
		} else if errors.Is(err, os.ErrPermission) {
			return protocol.NewErrorResponse(req.ID, protocol.ErrPermissionDenied, err.Error())
		} else {
			return protocol.NewErrorResponse(req.ID, protocol.ErrIO, err.Error())
		}
	}

	result := pathExistsResult{Exists: exists}
	raw, err := json.Marshal(result)
	if err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("marshal result: %v", err))
	}
	return protocol.NewSuccessResponse(req.ID, raw)
}

// ---------- stat_path ----------

type statPathArgs struct {
	Path string `json:"path"`
}

type statResult struct {
	Path      string `json:"path"`
	Size      int64  `json:"size"`
	Mtime     string `json:"mtime"`
	Mode      string `json:"mode"`
	IsDir     bool   `json:"is_dir"`
	IsSymlink bool   `json:"is_symlink"`
}

// statOne performs Lstat on a single path and returns the result or an error detail.
func statOne(path string) (*statResult, *protocol.ErrorDetail) {
	info, err := os.Lstat(path)
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

	mode := fmt.Sprintf("%04o", info.Mode().Perm())
	isSymlink := info.Mode()&os.ModeSymlink != 0

	return &statResult{
		Path:      path,
		Size:      info.Size(),
		Mtime:     info.ModTime().UTC().Format(time.RFC3339),
		Mode:      mode,
		IsDir:     info.IsDir(),
		IsSymlink: isSymlink,
	}, nil
}

// StatPath returns detailed stat information for a single path.
func StatPath(req protocol.Request) protocol.Response {
	var args statPathArgs
	if err := json.Unmarshal(req.Args, &args); err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("invalid args: %v", err))
	}

	result, errDetail := statOne(args.Path)
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

// ---------- stat_paths (batch) ----------

type statPathsArgs struct {
	Paths []string `json:"paths"`
}

type statPathError struct {
	Path  string               `json:"path"`
	Error protocol.ErrorDetail `json:"error"`
}

type statPathsResult struct {
	Results []statResult    `json:"results"`
	Errors  []statPathError `json:"errors"`
}

// StatPaths stats multiple paths in a batch. Individual failures go into the
// errors array rather than failing the entire request.
func StatPaths(req protocol.Request) protocol.Response {
	var args statPathsArgs
	if err := json.Unmarshal(req.Args, &args); err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("invalid args: %v", err))
	}

	result := statPathsResult{
		Results: []statResult{},
		Errors:  []statPathError{},
	}

	for _, path := range args.Paths {
		sr, errDetail := statOne(path)
		if errDetail != nil {
			result.Errors = append(result.Errors, statPathError{
				Path:  path,
				Error: *errDetail,
			})
		} else {
			result.Results = append(result.Results, *sr)
		}
	}

	raw, err := json.Marshal(result)
	if err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("marshal result: %v", err))
	}
	return protocol.NewSuccessResponse(req.ID, raw)
}
