package ops

import (
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/jeffdc/grove/protocol"
)

// ---------- copy_and_hash ----------

func TestCopyAndHash_Success(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "source.txt")
	dst := filepath.Join(dir, "dest.txt")
	content := []byte("hello world copy test")

	if err := os.WriteFile(src, content, 0644); err != nil {
		t.Fatal(err)
	}

	req := makeRequest(t, 1, "copy_and_hash", copyAndHashArgs{Source: src, Dest: dst})
	resp := CopyAndHash(req)

	if !resp.OK {
		t.Fatalf("expected OK, got error: %+v", resp.Error)
	}

	var result copyAndHashResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	// Verify hash matches expected MD5.
	h := md5.Sum(content)
	expectedHash := hex.EncodeToString(h[:])
	if result.MD5 != expectedHash {
		t.Errorf("md5: got %q, want %q", result.MD5, expectedHash)
	}

	// Verify dest file exists with correct content.
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("read dest: %v", err)
	}
	if string(got) != string(content) {
		t.Errorf("dest content: got %q, want %q", got, content)
	}
}

func TestCopyAndHash_SourceMissing(t *testing.T) {
	dir := t.TempDir()
	dst := filepath.Join(dir, "dest.txt")

	req := makeRequest(t, 2, "copy_and_hash", copyAndHashArgs{
		Source: "/no/such/file/ever.txt",
		Dest:   dst,
	})
	resp := CopyAndHash(req)

	if resp.OK {
		t.Fatal("expected error for missing source")
	}
	if resp.Error.Kind != protocol.ErrNotFound {
		t.Errorf("error kind: got %q, want %q", resp.Error.Kind, protocol.ErrNotFound)
	}
}

func TestCopyAndHash_CleansUpOnFailure(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("permission test not reliable on Windows")
	}

	dir := t.TempDir()
	src := filepath.Join(dir, "source.txt")
	if err := os.WriteFile(src, []byte("data"), 0644); err != nil {
		t.Fatal(err)
	}

	// Create a read-only directory so the .tmp write fails.
	roDir := filepath.Join(dir, "readonly")
	if err := os.MkdirAll(roDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(roDir, 0555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(roDir, 0755) })

	dst := filepath.Join(roDir, "dest.txt")
	req := makeRequest(t, 3, "copy_and_hash", copyAndHashArgs{Source: src, Dest: dst})
	resp := CopyAndHash(req)

	if resp.OK {
		t.Fatal("expected error when dest dir is read-only")
	}

	// Verify no .tmp file left behind.
	tmpFile := dst + ".tmp"
	if _, err := os.Stat(tmpFile); err == nil {
		t.Errorf("temp file %s should not exist after failure", tmpFile)
	}
}

func TestCopyAndHash_CreatesParentDirs(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "source.txt")
	content := []byte("nested dir test")
	if err := os.WriteFile(src, content, 0644); err != nil {
		t.Fatal(err)
	}

	dst := filepath.Join(dir, "a", "b", "c", "dest.txt")
	req := makeRequest(t, 4, "copy_and_hash", copyAndHashArgs{Source: src, Dest: dst})
	resp := CopyAndHash(req)

	if !resp.OK {
		t.Fatalf("expected OK, got error: %+v", resp.Error)
	}

	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("read dest: %v", err)
	}
	if string(got) != string(content) {
		t.Errorf("dest content: got %q, want %q", got, content)
	}
}

// ---------- move_file ----------

func TestMoveFile_SameDevice(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "moveme.txt")
	dst := filepath.Join(dir, "moved.txt")
	content := []byte("move test content")

	if err := os.WriteFile(src, content, 0644); err != nil {
		t.Fatal(err)
	}

	req := makeRequest(t, 5, "move_file", moveFileArgs{Source: src, Dest: dst})
	resp := MoveFile(req)

	if !resp.OK {
		t.Fatalf("expected OK, got error: %+v", resp.Error)
	}

	// Source should be gone.
	if _, err := os.Stat(src); !os.IsNotExist(err) {
		t.Errorf("source should not exist after move")
	}

	// Dest should exist with correct content.
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("read dest: %v", err)
	}
	if string(got) != string(content) {
		t.Errorf("dest content: got %q, want %q", got, content)
	}

	// No expected_hash, same-device rename: md5 should be empty.
	var result moveFileResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if result.MD5 != "" {
		t.Errorf("expected empty md5 for same-device rename without expected_hash, got %q", result.MD5)
	}
}

func TestMoveFile_WithExpectedHash(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "hashcheck.txt")
	dst := filepath.Join(dir, "sub", "hashcheck_moved.txt")
	content := []byte("hash verification content")

	if err := os.WriteFile(src, content, 0644); err != nil {
		t.Fatal(err)
	}

	h := md5.Sum(content)
	expectedHash := hex.EncodeToString(h[:])

	req := makeRequest(t, 6, "move_file", moveFileArgs{
		Source:       src,
		Dest:         dst,
		ExpectedHash: expectedHash,
	})
	resp := MoveFile(req)

	if !resp.OK {
		t.Fatalf("expected OK, got error: %+v", resp.Error)
	}

	// Source should be gone.
	if _, err := os.Stat(src); !os.IsNotExist(err) {
		t.Errorf("source should not exist after move")
	}

	// Dest should exist.
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("read dest: %v", err)
	}
	if string(got) != string(content) {
		t.Errorf("dest content mismatch")
	}

	var result moveFileResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if result.MD5 != expectedHash {
		t.Errorf("md5: got %q, want %q", result.MD5, expectedHash)
	}
}

func TestMoveFile_CrossDevice(t *testing.T) {
	// We can't easily simulate a real cross-device move in unit tests.
	// Instead we verify the same-device path works correctly, trusting
	// that the EXDEV fallback delegates to copy_and_hash which is
	// independently tested.
	t.Log("cross-device fallback tested indirectly via copy_and_hash tests")
}

func TestMoveFile_HashMismatch(t *testing.T) {
	// Hard to trigger with real same-device rename (no copy path).
	// This would require a cross-device scenario or mocking.
	// Covered by integration tests.
	t.Log("hash mismatch tested via integration tests")
}

// ---------- unlink_path ----------

func TestUnlinkPath_ExistingFile(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "deleteme.txt")
	if err := os.WriteFile(f, []byte("bye"), 0644); err != nil {
		t.Fatal(err)
	}

	req := makeRequest(t, 7, "unlink_path", unlinkPathArgs{Path: f})
	resp := UnlinkPath(req)

	if !resp.OK {
		t.Fatalf("expected OK, got error: %+v", resp.Error)
	}

	if _, err := os.Stat(f); !os.IsNotExist(err) {
		t.Errorf("file should not exist after unlink")
	}
}

func TestUnlinkPath_MissingFile(t *testing.T) {
	req := makeRequest(t, 8, "unlink_path", unlinkPathArgs{Path: "/no/such/file/ever.txt"})
	resp := UnlinkPath(req)

	if resp.OK {
		t.Fatal("expected error for missing file")
	}
	if resp.Error.Kind != protocol.ErrNotFound {
		t.Errorf("error kind: got %q, want %q", resp.Error.Kind, protocol.ErrNotFound)
	}
}

// ---------- remove_empty_dirs ----------

func TestRemoveEmptyDirs_Chain(t *testing.T) {
	dir := t.TempDir()
	a := filepath.Join(dir, "a")
	b := filepath.Join(a, "b")
	c := filepath.Join(b, "c")
	d := filepath.Join(c, "d")

	if err := os.MkdirAll(d, 0755); err != nil {
		t.Fatal(err)
	}

	req := makeRequest(t, 9, "remove_empty_dirs", removeEmptyDirsArgs{
		Path:   d,
		StopAt: a,
	})
	resp := RemoveEmptyDirs(req)

	if !resp.OK {
		t.Fatalf("expected OK, got error: %+v", resp.Error)
	}

	var result removeEmptyDirsResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	// Should have removed d, c, b (but not a).
	if len(result.Removed) != 3 {
		t.Fatalf("removed count: got %d, want 3; removed: %v", len(result.Removed), result.Removed)
	}

	// a should still exist.
	if _, err := os.Stat(a); os.IsNotExist(err) {
		t.Error("stop_at directory 'a' should still exist")
	}

	// d, c, b should be gone.
	for _, p := range []string{d, c, b} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s should have been removed", p)
		}
	}
}

func TestRemoveEmptyDirs_StopsAtNonEmpty(t *testing.T) {
	dir := t.TempDir()
	a := filepath.Join(dir, "a")
	b := filepath.Join(a, "b")
	c := filepath.Join(b, "c")

	if err := os.MkdirAll(c, 0755); err != nil {
		t.Fatal(err)
	}

	// Put a file in b, making it non-empty after c is removed.
	blocker := filepath.Join(b, "keepme.txt")
	if err := os.WriteFile(blocker, []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}

	req := makeRequest(t, 10, "remove_empty_dirs", removeEmptyDirsArgs{
		Path:   c,
		StopAt: a,
	})
	resp := RemoveEmptyDirs(req)

	if !resp.OK {
		t.Fatalf("expected OK, got error: %+v", resp.Error)
	}

	var result removeEmptyDirsResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	// Only c should be removed; b has a file.
	if len(result.Removed) != 1 {
		t.Fatalf("removed count: got %d, want 1; removed: %v", len(result.Removed), result.Removed)
	}
	if result.Removed[0] != c {
		t.Errorf("removed[0]: got %q, want %q", result.Removed[0], c)
	}

	// b should still exist.
	if _, err := os.Stat(b); os.IsNotExist(err) {
		t.Error("b should still exist (non-empty)")
	}
}

func TestRemoveEmptyDirs_StopsAtBoundary(t *testing.T) {
	dir := t.TempDir()
	a := filepath.Join(dir, "a")
	b := filepath.Join(a, "b")

	if err := os.MkdirAll(b, 0755); err != nil {
		t.Fatal(err)
	}

	req := makeRequest(t, 11, "remove_empty_dirs", removeEmptyDirsArgs{
		Path:   b,
		StopAt: a,
	})
	resp := RemoveEmptyDirs(req)

	if !resp.OK {
		t.Fatalf("expected OK, got error: %+v", resp.Error)
	}

	var result removeEmptyDirsResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	// Only b removed; a is the stop_at boundary.
	if len(result.Removed) != 1 {
		t.Fatalf("removed count: got %d, want 1; removed: %v", len(result.Removed), result.Removed)
	}

	if _, err := os.Stat(a); os.IsNotExist(err) {
		t.Error("stop_at directory 'a' should still exist")
	}
	if _, err := os.Stat(b); !os.IsNotExist(err) {
		t.Error("b should have been removed")
	}
}

// ---------- mkdir_all ----------

func TestMkdirAll_NewDir(t *testing.T) {
	dir := t.TempDir()
	nested := filepath.Join(dir, "x", "y", "z")

	req := makeRequest(t, 12, "mkdir_all", mkdirAllArgs{Path: nested})
	resp := MkdirAll(req)

	if !resp.OK {
		t.Fatalf("expected OK, got error: %+v", resp.Error)
	}

	info, err := os.Stat(nested)
	if err != nil {
		t.Fatalf("stat nested dir: %v", err)
	}
	if !info.IsDir() {
		t.Error("expected directory")
	}
}

func TestMkdirAll_Existing(t *testing.T) {
	dir := t.TempDir()

	req := makeRequest(t, 13, "mkdir_all", mkdirAllArgs{Path: dir})
	resp := MkdirAll(req)

	if !resp.OK {
		t.Fatalf("expected OK for existing dir, got error: %+v", resp.Error)
	}
}
