package ops

import (
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"github.com/jeffdc/grove/protocol"
)

// ---------- copy_and_hash ----------

type copyAndHashArgs struct {
	Source string `json:"source"`
	Dest   string `json:"dest"`
}

type copyAndHashResult struct {
	MD5 string `json:"md5"`
}

// CopyAndHash copies source to dest atomically (via .tmp file) and returns
// the MD5 hash computed during the copy.
func CopyAndHash(req protocol.Request) protocol.Response {
	var args copyAndHashArgs
	if err := json.Unmarshal(req.Args, &args); err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("invalid args: %v", err))
	}

	hash, err := doCopyAndHash(args.Source, args.Dest)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return protocol.NewErrorResponse(req.ID, protocol.ErrNotFound, err.Error())
		}
		if errors.Is(err, os.ErrPermission) {
			return protocol.NewErrorResponse(req.ID, protocol.ErrPermissionDenied, err.Error())
		}
		return protocol.NewErrorResponse(req.ID, protocol.ErrIO, err.Error())
	}

	result := copyAndHashResult{MD5: hash}
	raw, marshalErr := json.Marshal(result)
	if marshalErr != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("marshal result: %v", marshalErr))
	}
	return protocol.NewSuccessResponse(req.ID, raw)
}

// doCopyAndHash performs the actual copy+hash operation, returning the hex MD5
// or an error. It writes to a .tmp file and renames on success.
func doCopyAndHash(source, dest string) (string, error) {
	srcFile, err := os.Open(source)
	if err != nil {
		return "", err
	}
	defer srcFile.Close()

	// Ensure parent directories exist.
	if err := os.MkdirAll(filepath.Dir(dest), 0755); err != nil {
		return "", err
	}

	tmpPath := dest + ".tmp"
	tmpFile, err := os.Create(tmpPath)
	if err != nil {
		return "", err
	}

	hasher := md5.New()
	w := io.MultiWriter(tmpFile, hasher)

	_, copyErr := io.Copy(w, srcFile)

	// Always try to close the temp file before handling errors.
	closeErr := tmpFile.Close()

	if copyErr != nil {
		os.Remove(tmpPath)
		return "", copyErr
	}
	if closeErr != nil {
		os.Remove(tmpPath)
		return "", closeErr
	}

	// Atomic rename .tmp -> dest.
	if err := os.Rename(tmpPath, dest); err != nil {
		os.Remove(tmpPath)
		return "", err
	}

	hash := hex.EncodeToString(hasher.Sum(nil))
	return hash, nil
}

// ---------- move_file ----------

type moveFileArgs struct {
	Source       string `json:"source"`
	Dest         string `json:"dest"`
	ExpectedHash string `json:"expected_hash"`
}

type moveFileResult struct {
	MD5 string `json:"md5"`
}

// MoveFile moves source to dest. It tries os.Rename first (atomic, same-device).
// If that fails with EXDEV, it falls back to copy_and_hash + delete source.
func MoveFile(req protocol.Request) protocol.Response {
	var args moveFileArgs
	if err := json.Unmarshal(req.Args, &args); err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("invalid args: %v", err))
	}

	// Ensure parent directories exist.
	if err := os.MkdirAll(filepath.Dir(args.Dest), 0755); err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrIO, err.Error())
	}

	// Try rename first.
	renameErr := os.Rename(args.Source, args.Dest)

	if renameErr == nil {
		// Same-device rename succeeded.
		md5Hash := ""
		if args.ExpectedHash != "" {
			// Need to hash the file to verify.
			computed, err := hashFile(args.Dest)
			if err != nil {
				return protocol.NewErrorResponse(req.ID, protocol.ErrIO, err.Error())
			}
			if computed != args.ExpectedHash {
				// Hash mismatch: move the file back and report error.
				_ = os.Rename(args.Dest, args.Source)
				return protocol.NewErrorResponse(req.ID, protocol.ErrIO,
					fmt.Sprintf("hash mismatch: expected %s, got %s", args.ExpectedHash, computed))
			}
			md5Hash = computed
		}

		result := moveFileResult{MD5: md5Hash}
		raw, err := json.Marshal(result)
		if err != nil {
			return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
				fmt.Sprintf("marshal result: %v", err))
		}
		return protocol.NewSuccessResponse(req.ID, raw)
	}

	// Check for cross-device error.
	var linkErr *os.LinkError
	if errors.As(renameErr, &linkErr) && errors.Is(linkErr.Err, syscall.EXDEV) {
		// Cross-device: fall back to copy + hash + delete.
		hash, err := doCopyAndHash(args.Source, args.Dest)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				return protocol.NewErrorResponse(req.ID, protocol.ErrNotFound, err.Error())
			}
			return protocol.NewErrorResponse(req.ID, protocol.ErrIO, err.Error())
		}

		// Verify hash if expected.
		if args.ExpectedHash != "" && hash != args.ExpectedHash {
			os.Remove(args.Dest)
			return protocol.NewErrorResponse(req.ID, protocol.ErrIO,
				fmt.Sprintf("hash mismatch: expected %s, got %s", args.ExpectedHash, hash))
		}

		// Copy succeeded, remove source.
		if err := os.Remove(args.Source); err != nil {
			return protocol.NewErrorResponse(req.ID, protocol.ErrIO,
				fmt.Sprintf("copied ok but failed to remove source: %v", err))
		}

		result := moveFileResult{MD5: hash}
		raw, err := json.Marshal(result)
		if err != nil {
			return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
				fmt.Sprintf("marshal result: %v", err))
		}
		return protocol.NewSuccessResponse(req.ID, raw)
	}

	// Non-EXDEV rename error.
	if errors.Is(renameErr, os.ErrNotExist) {
		return protocol.NewErrorResponse(req.ID, protocol.ErrNotFound, renameErr.Error())
	}
	return protocol.NewErrorResponse(req.ID, protocol.ErrIO, renameErr.Error())
}

// hashFile computes the MD5 of a file and returns the hex string.
func hashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()

	hasher := md5.New()
	if _, err := io.Copy(hasher, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

// ---------- unlink_path ----------

type unlinkPathArgs struct {
	Path string `json:"path"`
}

// UnlinkPath removes a file at the given path.
func UnlinkPath(req protocol.Request) protocol.Response {
	var args unlinkPathArgs
	if err := json.Unmarshal(req.Args, &args); err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("invalid args: %v", err))
	}

	if err := os.Remove(args.Path); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return protocol.NewErrorResponse(req.ID, protocol.ErrNotFound, err.Error())
		}
		if errors.Is(err, os.ErrPermission) {
			return protocol.NewErrorResponse(req.ID, protocol.ErrPermissionDenied, err.Error())
		}
		return protocol.NewErrorResponse(req.ID, protocol.ErrIO, err.Error())
	}

	return protocol.NewSuccessResponse(req.ID, json.RawMessage(`{}`))
}

// ---------- remove_empty_dirs ----------

type removeEmptyDirsArgs struct {
	Path   string `json:"path"`
	StopAt string `json:"stop_at"`
}

type removeEmptyDirsResult struct {
	Removed []string `json:"removed"`
}

// RemoveEmptyDirs walks upward from path, removing empty directories, stopping
// at stop_at (never removing stop_at itself) or when a directory is not empty.
func RemoveEmptyDirs(req protocol.Request) protocol.Response {
	var args removeEmptyDirsArgs
	if err := json.Unmarshal(req.Args, &args); err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("invalid args: %v", err))
	}

	// Clean paths so comparisons work reliably.
	current := filepath.Clean(args.Path)
	stopAt := filepath.Clean(args.StopAt)

	var removed []string

	for current != stopAt {
		err := os.Remove(current)
		if err != nil {
			// Directory not empty or other error: stop walking.
			break
		}
		removed = append(removed, current)
		current = filepath.Dir(current)
	}

	result := removeEmptyDirsResult{Removed: removed}
	if result.Removed == nil {
		result.Removed = []string{}
	}
	raw, err := json.Marshal(result)
	if err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("marshal result: %v", err))
	}
	return protocol.NewSuccessResponse(req.ID, raw)
}

// ---------- mkdir_all ----------

type mkdirAllArgs struct {
	Path string `json:"path"`
}

// MkdirAll creates the directory path along with any necessary parents.
func MkdirAll(req protocol.Request) protocol.Response {
	var args mkdirAllArgs
	if err := json.Unmarshal(req.Args, &args); err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("invalid args: %v", err))
	}

	if err := os.MkdirAll(args.Path, 0755); err != nil {
		if errors.Is(err, os.ErrPermission) {
			return protocol.NewErrorResponse(req.ID, protocol.ErrPermissionDenied, err.Error())
		}
		return protocol.NewErrorResponse(req.ID, protocol.ErrIO, err.Error())
	}

	return protocol.NewSuccessResponse(req.ID, json.RawMessage(`{}`))
}
