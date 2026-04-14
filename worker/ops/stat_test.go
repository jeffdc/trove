package ops

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jeffdc/grove/protocol"
)

// helper: build a protocol.Request with the given op and args struct.
func makeRequest(t *testing.T, id int64, op string, args any) protocol.Request {
	t.Helper()
	raw, err := json.Marshal(args)
	if err != nil {
		t.Fatalf("marshal args: %v", err)
	}
	return protocol.Request{ID: id, Op: op, Args: raw}
}

// ---------- path_exists ----------

func TestPathExists_ExistingFile(t *testing.T) {
	tmp := filepath.Join(t.TempDir(), "exists.txt")
	if err := os.WriteFile(tmp, []byte("hello"), 0644); err != nil {
		t.Fatal(err)
	}

	req := makeRequest(t, 1, "path_exists", pathExistsArgs{Path: tmp})
	resp := PathExists(req)

	if !resp.OK {
		t.Fatalf("expected OK response, got error: %+v", resp.Error)
	}

	var result pathExistsResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if !result.Exists {
		t.Errorf("expected exists=true, got false")
	}
}

func TestPathExists_MissingFile(t *testing.T) {
	req := makeRequest(t, 2, "path_exists", pathExistsArgs{Path: "/no/such/path/ever"})
	resp := PathExists(req)

	if !resp.OK {
		t.Fatalf("expected OK response (exists=false), got error: %+v", resp.Error)
	}

	var result pathExistsResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if result.Exists {
		t.Errorf("expected exists=false, got true")
	}
}

// ---------- stat_path ----------

func TestStatPath_ExistingFile(t *testing.T) {
	tmp := filepath.Join(t.TempDir(), "data.txt")
	content := []byte("some content")
	if err := os.WriteFile(tmp, content, 0644); err != nil {
		t.Fatal(err)
	}

	req := makeRequest(t, 3, "stat_path", statPathArgs{Path: tmp})
	resp := StatPath(req)

	if !resp.OK {
		t.Fatalf("expected OK response, got error: %+v", resp.Error)
	}

	var result statResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	if result.Path != tmp {
		t.Errorf("path: got %q, want %q", result.Path, tmp)
	}
	if result.Size != int64(len(content)) {
		t.Errorf("size: got %d, want %d", result.Size, len(content))
	}
	if result.IsDir {
		t.Error("expected is_dir=false")
	}
	if result.IsSymlink {
		t.Error("expected is_symlink=false")
	}

	// Mode should be an octal string.
	if result.Mode != "0644" {
		t.Errorf("mode: got %q, want %q", result.Mode, "0644")
	}

	// Mtime should be a valid UTC ISO 8601 timestamp, recent.
	mt, err := time.Parse(time.RFC3339, result.Mtime)
	if err != nil {
		t.Fatalf("mtime not valid RFC3339: %v", err)
	}
	if time.Since(mt) > 10*time.Second {
		t.Errorf("mtime too old: %v", mt)
	}
}

func TestStatPath_Directory(t *testing.T) {
	dir := t.TempDir()

	req := makeRequest(t, 4, "stat_path", statPathArgs{Path: dir})
	resp := StatPath(req)

	if !resp.OK {
		t.Fatalf("expected OK response, got error: %+v", resp.Error)
	}

	var result statResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	if !result.IsDir {
		t.Error("expected is_dir=true for directory")
	}
}

func TestStatPath_MissingFile(t *testing.T) {
	req := makeRequest(t, 5, "stat_path", statPathArgs{Path: "/no/such/path/ever"})
	resp := StatPath(req)

	if resp.OK {
		t.Fatal("expected error response for missing file")
	}
	if resp.Error == nil {
		t.Fatal("expected error detail")
	}
	if resp.Error.Kind != protocol.ErrNotFound {
		t.Errorf("error kind: got %q, want %q", resp.Error.Kind, protocol.ErrNotFound)
	}
}

// ---------- stat_paths (batch) ----------

func TestStatPaths_Mixed(t *testing.T) {
	dir := t.TempDir()

	// Create two files; leave a third path non-existent.
	fileA := filepath.Join(dir, "a.txt")
	fileB := filepath.Join(dir, "b.txt")
	fileC := filepath.Join(dir, "c.txt") // will not exist

	if err := os.WriteFile(fileA, []byte("aaa"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fileB, []byte("bb"), 0600); err != nil {
		t.Fatal(err)
	}

	req := makeRequest(t, 6, "stat_paths", statPathsArgs{Paths: []string{fileA, fileB, fileC}})
	resp := StatPaths(req)

	if !resp.OK {
		t.Fatalf("expected OK response, got error: %+v", resp.Error)
	}

	var result statPathsResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	// Two successes, one error.
	if len(result.Results) != 2 {
		t.Errorf("results count: got %d, want 2", len(result.Results))
	}
	if len(result.Errors) != 1 {
		t.Fatalf("errors count: got %d, want 1", len(result.Errors))
	}

	// Verify the error is for fileC with not_found kind.
	if result.Errors[0].Path != fileC {
		t.Errorf("error path: got %q, want %q", result.Errors[0].Path, fileC)
	}
	if result.Errors[0].Error.Kind != protocol.ErrNotFound {
		t.Errorf("error kind: got %q, want %q", result.Errors[0].Error.Kind, protocol.ErrNotFound)
	}

	// Verify the successful results contain the right paths.
	paths := map[string]bool{}
	for _, r := range result.Results {
		paths[r.Path] = true
	}
	if !paths[fileA] {
		t.Errorf("missing result for %s", fileA)
	}
	if !paths[fileB] {
		t.Errorf("missing result for %s", fileB)
	}

	// Verify sizes.
	for _, r := range result.Results {
		switch r.Path {
		case fileA:
			if r.Size != 3 {
				t.Errorf("fileA size: got %d, want 3", r.Size)
			}
		case fileB:
			if r.Size != 2 {
				t.Errorf("fileB size: got %d, want 2", r.Size)
			}
		}
	}
}
