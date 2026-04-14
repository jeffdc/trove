package ops

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/jeffdc/grove/protocol"
)

// helper to build a walk_tree request from typed args.
func walkRequest(id int64, args walkTreeArgs) protocol.Request {
	raw, _ := json.Marshal(args)
	return protocol.Request{ID: id, Op: "walk_tree", Args: raw}
}

// helper to decode a successful walk_tree result.
func decodeWalkResult(t *testing.T, resp protocol.Response) walkTreeResult {
	t.Helper()
	if !resp.OK {
		t.Fatalf("expected OK response, got error: %+v", resp.Error)
	}
	var result walkTreeResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("failed to unmarshal result: %v", err)
	}
	return result
}

// writeFile creates a file with the given content inside dir.
func writeFile(t *testing.T, dir, name, content string) {
	t.Helper()
	full := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestWalkTree_BasicWalk(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "photo.jpg", "jpeg data")
	writeFile(t, root, "readme.txt", "hello")
	writeFile(t, root, "image.png", "png data")

	req := walkRequest(1, walkTreeArgs{
		Root:       root,
		Extensions: []string{".jpg"},
	})
	resp := WalkTree(req)
	result := decodeWalkResult(t, resp)

	if len(result.Files) != 1 {
		t.Fatalf("expected 1 file, got %d: %+v", len(result.Files), result.Files)
	}
	if result.Files[0].Path != "photo.jpg" {
		t.Errorf("expected path %q, got %q", "photo.jpg", result.Files[0].Path)
	}
	if result.Files[0].Size != int64(len("jpeg data")) {
		t.Errorf("expected size %d, got %d", len("jpeg data"), result.Files[0].Size)
	}
	if result.Files[0].Mtime == "" {
		t.Error("expected non-empty mtime")
	}
}

func TestWalkTree_ExcludePatterns(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "photo.jpg", "jpeg data")
	writeFile(t, root, ".DS_Store", "ds store data")
	writeFile(t, root, "._hidden", "hidden data")
	writeFile(t, root, "Thumbs.db", "thumbs data")

	req := walkRequest(2, walkTreeArgs{
		Root:            root,
		ExcludePatterns: []string{"*.DS_Store", "._*", "Thumbs.db"},
	})
	resp := WalkTree(req)
	result := decodeWalkResult(t, resp)

	if len(result.Files) != 1 {
		t.Fatalf("expected 1 file, got %d: %+v", len(result.Files), result.Files)
	}
	if result.Files[0].Path != "photo.jpg" {
		t.Errorf("expected path %q, got %q", "photo.jpg", result.Files[0].Path)
	}
}

func TestWalkTree_SkipSymlinks(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks may not be supported on Windows")
	}
	root := t.TempDir()
	writeFile(t, root, "real.jpg", "jpeg data")

	target := filepath.Join(root, "real.jpg")
	link := filepath.Join(root, "link.jpg")
	if err := os.Symlink(target, link); err != nil {
		t.Skip("symlinks not supported:", err)
	}

	req := walkRequest(3, walkTreeArgs{Root: root})
	resp := WalkTree(req)
	result := decodeWalkResult(t, resp)

	if len(result.Files) != 1 {
		t.Fatalf("expected 1 file, got %d: %+v", len(result.Files), result.Files)
	}
	if result.Files[0].Path != "real.jpg" {
		t.Errorf("expected path %q, got %q", "real.jpg", result.Files[0].Path)
	}
}

func TestWalkTree_SkipZeroByteFiles(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "nonempty.jpg", "data")
	writeFile(t, root, "empty.jpg", "")

	req := walkRequest(4, walkTreeArgs{Root: root})
	resp := WalkTree(req)
	result := decodeWalkResult(t, resp)

	if len(result.Files) != 1 {
		t.Fatalf("expected 1 file, got %d: %+v", len(result.Files), result.Files)
	}
	if result.Files[0].Path != "nonempty.jpg" {
		t.Errorf("expected path %q, got %q", "nonempty.jpg", result.Files[0].Path)
	}
}

func TestWalkTree_NestedDirectories(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "top.jpg", "top")
	writeFile(t, root, "2024/01/photo.jpg", "nested")
	writeFile(t, root, "2024/02/other.jpg", "deep")

	req := walkRequest(5, walkTreeArgs{
		Root:       root,
		Extensions: []string{".jpg"},
	})
	resp := WalkTree(req)
	result := decodeWalkResult(t, resp)

	if len(result.Files) != 3 {
		t.Fatalf("expected 3 files, got %d: %+v", len(result.Files), result.Files)
	}

	paths := make(map[string]bool)
	for _, f := range result.Files {
		paths[f.Path] = true
	}

	expected := []string{"top.jpg", "2024/01/photo.jpg", "2024/02/other.jpg"}
	for _, p := range expected {
		if !paths[p] {
			t.Errorf("expected path %q in results, got paths: %v", p, paths)
		}
	}
}

func TestWalkTree_EmptyDir(t *testing.T) {
	root := t.TempDir()

	req := walkRequest(6, walkTreeArgs{Root: root})
	resp := WalkTree(req)
	result := decodeWalkResult(t, resp)

	if result.Files == nil {
		t.Fatal("expected non-nil files slice (should be empty array, not null)")
	}
	if len(result.Files) != 0 {
		t.Fatalf("expected 0 files, got %d: %+v", len(result.Files), result.Files)
	}
}

func TestWalkTree_NonExistentRoot(t *testing.T) {
	req := walkRequest(7, walkTreeArgs{Root: "/tmp/nonexistent-walk-test-dir-" + t.Name()})
	resp := WalkTree(req)

	if resp.OK {
		t.Fatal("expected error response for non-existent root")
	}
	if resp.Error == nil {
		t.Fatal("expected error detail to be set")
	}
	if resp.Error.Kind != protocol.ErrNotFound {
		t.Errorf("expected error kind %q, got %q", protocol.ErrNotFound, resp.Error.Kind)
	}
}

func TestWalkTree_NoExtensionFilter(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "photo.jpg", "jpeg data")
	writeFile(t, root, "readme.txt", "hello")
	writeFile(t, root, "data.bin", "binary")

	req := walkRequest(8, walkTreeArgs{Root: root})
	resp := WalkTree(req)
	result := decodeWalkResult(t, resp)

	if len(result.Files) != 3 {
		t.Fatalf("expected 3 files, got %d: %+v", len(result.Files), result.Files)
	}
}

func TestWalkTree_CaseInsensitiveExtensions(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "photo.JPG", "jpeg upper")
	writeFile(t, root, "image.jpg", "jpeg lower")
	writeFile(t, root, "other.Jpg", "jpeg mixed")
	writeFile(t, root, "readme.txt", "text")

	req := walkRequest(9, walkTreeArgs{
		Root:       root,
		Extensions: []string{".jpg"},
	})
	resp := WalkTree(req)
	result := decodeWalkResult(t, resp)

	if len(result.Files) != 3 {
		t.Fatalf("expected 3 files, got %d: %+v", len(result.Files), result.Files)
	}
}

func TestWalkTree_InvalidArgs(t *testing.T) {
	req := protocol.Request{ID: 10, Op: "walk_tree", Args: json.RawMessage(`{not valid`)}
	resp := WalkTree(req)

	if resp.OK {
		t.Fatal("expected error response for invalid JSON args")
	}
	if resp.Error == nil {
		t.Fatal("expected error detail to be set")
	}
}

func TestWalkTree_RootIsFile(t *testing.T) {
	root := t.TempDir()
	filePath := filepath.Join(root, "afile.txt")
	if err := os.WriteFile(filePath, []byte("content"), 0o644); err != nil {
		t.Fatal(err)
	}

	req := walkRequest(11, walkTreeArgs{Root: filePath})
	resp := WalkTree(req)

	if resp.OK {
		t.Fatal("expected error response when root is a file")
	}
	if resp.Error.Kind != protocol.ErrIO {
		t.Errorf("expected error kind %q, got %q", protocol.ErrIO, resp.Error.Kind)
	}
}
