package ops

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/jeffdc/grove/protocol"
)

type walkTreeArgs struct {
	Root            string   `json:"root"`
	Extensions      []string `json:"extensions"`
	ExcludePatterns []string `json:"exclude_patterns"`
}

type walkTreeFileEntry struct {
	Path  string `json:"path"`
	Size  int64  `json:"size"`
	Mtime string `json:"mtime"`
}

type walkTreeResult struct {
	Files []walkTreeFileEntry `json:"files"`
}

// WalkTree recursively walks a directory tree and returns matching file entries.
func WalkTree(req protocol.Request) protocol.Response {
	var args walkTreeArgs
	if err := json.Unmarshal(req.Args, &args); err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("invalid walk_tree args: %v", err))
	}

	// Check that root exists.
	info, err := os.Stat(args.Root)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return protocol.NewErrorResponse(req.ID, protocol.ErrNotFound,
				fmt.Sprintf("root does not exist: %s", args.Root))
		}
		return protocol.NewErrorResponse(req.ID, protocol.ErrIO,
			fmt.Sprintf("cannot stat root: %v", err))
	}

	// Check that root is a directory.
	if !info.IsDir() {
		return protocol.NewErrorResponse(req.ID, protocol.ErrIO,
			fmt.Sprintf("root is not a directory: %s", args.Root))
	}

	// Normalize extensions to lowercase for case-insensitive comparison.
	extSet := make(map[string]bool, len(args.Extensions))
	for _, ext := range args.Extensions {
		extSet[strings.ToLower(ext)] = true
	}
	filterByExt := len(extSet) > 0

	files := make([]walkTreeFileEntry, 0)

	walkErr := filepath.WalkDir(args.Root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			// Skip entries we can't access rather than aborting the whole walk.
			return nil
		}

		// Skip directories (we only collect files).
		if d.IsDir() {
			return nil
		}

		// Skip symlinks.
		if d.Type()&os.ModeSymlink != 0 {
			return nil
		}

		name := d.Name()

		// Check exclude patterns against the filename.
		for _, pattern := range args.ExcludePatterns {
			matched, matchErr := filepath.Match(pattern, name)
			if matchErr != nil {
				continue // invalid pattern, skip it
			}
			if matched {
				return nil
			}
		}

		// Check extension filter.
		if filterByExt {
			ext := strings.ToLower(filepath.Ext(name))
			if !extSet[ext] {
				return nil
			}
		}

		// Get file info for size and mtime; skip zero-byte files.
		fi, fiErr := d.Info()
		if fiErr != nil {
			return nil // skip files we can't stat
		}
		if fi.Size() == 0 {
			return nil
		}

		// Compute relative path from root.
		relPath, relErr := filepath.Rel(args.Root, path)
		if relErr != nil {
			return nil
		}
		relPath = filepath.ToSlash(relPath)

		files = append(files, walkTreeFileEntry{
			Path:  relPath,
			Size:  fi.Size(),
			Mtime: fi.ModTime().UTC().Format("2006-01-02T15:04:05Z"),
		})

		return nil
	})

	if walkErr != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrIO,
			fmt.Sprintf("walk error: %v", walkErr))
	}

	result := walkTreeResult{Files: files}
	raw, err := json.Marshal(result)
	if err != nil {
		return protocol.NewErrorResponse(req.ID, protocol.ErrUnknown,
			fmt.Sprintf("failed to marshal result: %v", err))
	}

	return protocol.NewSuccessResponse(req.ID, raw)
}
