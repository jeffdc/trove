package integration_test

import (
	"bufio"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"testing"
)

// workerBin is the path to the compiled worker binary, built once in TestMain.
var workerBin string

func TestMain(m *testing.M) {
	tmpDir, err := os.MkdirTemp("", "grove-integration-*")
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create temp dir: %v\n", err)
		os.Exit(1)
	}
	defer os.RemoveAll(tmpDir)

	workerBin = filepath.Join(tmpDir, "worker")
	cmd := exec.Command("go", "build", "-o", workerBin, "./cmd/worker")
	cmd.Dir = "."
	if out, err := cmd.CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "failed to build worker: %v\n%s\n", err, out)
		os.Exit(1)
	}

	os.Exit(m.Run())
}

// --- protocol types for test unmarshaling ---

type helloMessage struct {
	ProtocolVersion int      `json:"protocol_version"`
	WorkerVersion   string   `json:"worker_version"`
	Capabilities    []string `json:"capabilities"`
}

type response struct {
	ID     int64            `json:"id"`
	OK     bool             `json:"ok"`
	Result json.RawMessage  `json:"result,omitempty"`
	Error  *errorDetail     `json:"error,omitempty"`
}

type errorDetail struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
}

// --- worker subprocess helper ---

type workerProc struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout *bufio.Scanner
	hello  helloMessage
}

func startWorker(t *testing.T) *workerProc {
	t.Helper()

	cmd := exec.Command(workerBin)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("StdinPipe: %v", err)
	}
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("StdoutPipe: %v", err)
	}
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}

	scanner := bufio.NewScanner(stdoutPipe)
	scanner.Buffer(make([]byte, 0, 64*1024), 10*1024*1024)

	// Read the hello message.
	if !scanner.Scan() {
		cmd.Process.Kill()
		t.Fatalf("failed to read hello: %v", scanner.Err())
	}

	var hello helloMessage
	if err := json.Unmarshal(scanner.Bytes(), &hello); err != nil {
		cmd.Process.Kill()
		t.Fatalf("unmarshal hello: %v", err)
	}

	w := &workerProc{
		cmd:    cmd,
		stdin:  stdin,
		stdout: scanner,
		hello:  hello,
	}

	t.Cleanup(func() {
		stdin.Close()
		cmd.Wait()
	})

	return w
}

// sendRequest writes a JSON request to the worker's stdin and reads back one response.
func (w *workerProc) sendRequest(t *testing.T, id int64, op string, args any) response {
	t.Helper()

	argsJSON, err := json.Marshal(args)
	if err != nil {
		t.Fatalf("marshal args: %v", err)
	}

	req := struct {
		ID   int64           `json:"id"`
		Op   string          `json:"op"`
		Args json.RawMessage `json:"args"`
	}{
		ID:   id,
		Op:   op,
		Args: argsJSON,
	}

	line, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	line = append(line, '\n')

	if _, err := w.stdin.Write(line); err != nil {
		t.Fatalf("write request: %v", err)
	}

	if !w.stdout.Scan() {
		t.Fatalf("no response (scan error: %v)", w.stdout.Err())
	}

	var resp response
	if err := json.Unmarshal(w.stdout.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal response: %v\nraw: %s", err, w.stdout.Text())
	}

	return resp
}

// sendRawLine writes an arbitrary string followed by newline to stdin, reads one response.
func (w *workerProc) sendRawLine(t *testing.T, line string) response {
	t.Helper()

	if _, err := w.stdin.Write([]byte(line + "\n")); err != nil {
		t.Fatalf("write raw: %v", err)
	}

	if !w.stdout.Scan() {
		t.Fatalf("no response (scan error: %v)", w.stdout.Err())
	}

	var resp response
	if err := json.Unmarshal(w.stdout.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal response: %v\nraw: %s", err, w.stdout.Text())
	}

	return resp
}

// --- Tests ---

func TestIntegration_Hello(t *testing.T) {
	w := startWorker(t)

	if w.hello.ProtocolVersion != 1 {
		t.Errorf("protocol_version: got %d, want 1", w.hello.ProtocolVersion)
	}
	if w.hello.WorkerVersion == "" {
		t.Error("worker_version is empty")
	}

	expectedCaps := []string{
		"check_mount", "path_exists", "stat_path", "stat_paths",
		"walk_tree", "hash_path", "hash_paths", "copy_and_hash",
		"move_file", "unlink_path", "mkdir_all", "remove_empty_dirs",
	}

	if len(w.hello.Capabilities) != len(expectedCaps) {
		t.Fatalf("capabilities count: got %d, want %d", len(w.hello.Capabilities), len(expectedCaps))
	}
	capSet := make(map[string]bool)
	for _, c := range w.hello.Capabilities {
		capSet[c] = true
	}
	for _, want := range expectedCaps {
		if !capSet[want] {
			t.Errorf("missing capability: %s", want)
		}
	}

	// Close stdin, verify clean exit.
	w.stdin.Close()
	err := w.cmd.Wait()
	if err != nil {
		t.Errorf("worker exit error: %v", err)
	}
}

func TestIntegration_WalkAndHash(t *testing.T) {
	w := startWorker(t)

	// Create a temp directory with some files.
	tmpDir := t.TempDir()
	writeFile(t, filepath.Join(tmpDir, "photo.jpg"), "jpeg data here")
	writeFile(t, filepath.Join(tmpDir, "doc.txt"), "some text")
	os.MkdirAll(filepath.Join(tmpDir, "subdir"), 0755)
	writeFile(t, filepath.Join(tmpDir, "subdir", "nested.jpg"), "nested jpeg")

	// Walk the tree.
	resp := w.sendRequest(t, 1, "walk_tree", map[string]any{
		"root":       tmpDir,
		"extensions": []string{".jpg"},
	})

	if !resp.OK {
		t.Fatalf("walk_tree failed: %v", resp.Error)
	}

	var walkResult struct {
		Files []struct {
			Path  string `json:"path"`
			Size  int64  `json:"size"`
			Mtime string `json:"mtime"`
		} `json:"files"`
	}
	if err := json.Unmarshal(resp.Result, &walkResult); err != nil {
		t.Fatalf("unmarshal walk result: %v", err)
	}

	if len(walkResult.Files) != 2 {
		t.Fatalf("walk_tree returned %d files, want 2", len(walkResult.Files))
	}

	// Collect the relative paths returned.
	pathSet := make(map[string]bool)
	for _, f := range walkResult.Files {
		pathSet[f.Path] = true
	}
	if !pathSet["photo.jpg"] {
		t.Error("walk_tree missing photo.jpg")
	}
	if !pathSet["subdir/nested.jpg"] {
		t.Error("walk_tree missing subdir/nested.jpg")
	}

	// Hash one of the files.
	photoPath := filepath.Join(tmpDir, "photo.jpg")
	hashResp := w.sendRequest(t, 2, "hash_path", map[string]any{
		"path": photoPath,
	})

	if !hashResp.OK {
		t.Fatalf("hash_path failed: %v", hashResp.Error)
	}

	var hashResult struct {
		Path string `json:"path"`
		MD5  string `json:"md5"`
	}
	if err := json.Unmarshal(hashResp.Result, &hashResult); err != nil {
		t.Fatalf("unmarshal hash result: %v", err)
	}

	// Verify the hash is a 32-char hex string (MD5).
	if matched, _ := regexp.MatchString(`^[0-9a-f]{32}$`, hashResult.MD5); !matched {
		t.Errorf("hash_path md5 %q is not valid hex MD5", hashResult.MD5)
	}

	// Verify it matches what we expect.
	expectedHash := md5hex("jpeg data here")
	if hashResult.MD5 != expectedHash {
		t.Errorf("hash_path md5: got %s, want %s", hashResult.MD5, expectedHash)
	}
}

func TestIntegration_CopyAndVerify(t *testing.T) {
	w := startWorker(t)
	tmpDir := t.TempDir()

	content := "known file content for copy test"
	srcPath := filepath.Join(tmpDir, "source.dat")
	dstPath := filepath.Join(tmpDir, "dest.dat")
	writeFile(t, srcPath, content)

	// Copy and hash.
	resp := w.sendRequest(t, 1, "copy_and_hash", map[string]any{
		"source": srcPath,
		"dest":   dstPath,
	})

	if !resp.OK {
		t.Fatalf("copy_and_hash failed: %v", resp.Error)
	}

	var copyResult struct {
		MD5 string `json:"md5"`
	}
	if err := json.Unmarshal(resp.Result, &copyResult); err != nil {
		t.Fatalf("unmarshal copy result: %v", err)
	}

	expectedHash := md5hex(content)
	if copyResult.MD5 != expectedHash {
		t.Errorf("copy_and_hash md5: got %s, want %s", copyResult.MD5, expectedHash)
	}

	// Stat the destination to verify it exists with correct size.
	statResp := w.sendRequest(t, 2, "stat_path", map[string]any{
		"path": dstPath,
	})

	if !statResp.OK {
		t.Fatalf("stat_path failed: %v", statResp.Error)
	}

	var statResult struct {
		Path  string `json:"path"`
		Size  int64  `json:"size"`
		IsDir bool   `json:"is_dir"`
	}
	if err := json.Unmarshal(statResp.Result, &statResult); err != nil {
		t.Fatalf("unmarshal stat result: %v", err)
	}

	if statResult.Size != int64(len(content)) {
		t.Errorf("dest size: got %d, want %d", statResult.Size, len(content))
	}
	if statResult.IsDir {
		t.Error("dest should not be a directory")
	}
}

func TestIntegration_MoveFile(t *testing.T) {
	w := startWorker(t)
	tmpDir := t.TempDir()

	content := "file to be moved"
	srcPath := filepath.Join(tmpDir, "original.txt")
	dstPath := filepath.Join(tmpDir, "moved.txt")
	writeFile(t, srcPath, content)

	// Move the file.
	resp := w.sendRequest(t, 1, "move_file", map[string]any{
		"source": srcPath,
		"dest":   dstPath,
	})

	if !resp.OK {
		t.Fatalf("move_file failed: %v", resp.Error)
	}

	// Source should be gone.
	existsResp := w.sendRequest(t, 2, "path_exists", map[string]any{
		"path": srcPath,
	})
	if !existsResp.OK {
		t.Fatalf("path_exists failed: %v", existsResp.Error)
	}
	var existsResult struct {
		Exists bool `json:"exists"`
	}
	if err := json.Unmarshal(existsResp.Result, &existsResult); err != nil {
		t.Fatalf("unmarshal exists result: %v", err)
	}
	if existsResult.Exists {
		t.Error("source file still exists after move")
	}

	// Dest should exist.
	statResp := w.sendRequest(t, 3, "stat_path", map[string]any{
		"path": dstPath,
	})
	if !statResp.OK {
		t.Fatalf("stat_path on dest failed: %v", statResp.Error)
	}
	var statResult struct {
		Size int64 `json:"size"`
	}
	if err := json.Unmarshal(statResp.Result, &statResult); err != nil {
		t.Fatalf("unmarshal stat result: %v", err)
	}
	if statResult.Size != int64(len(content)) {
		t.Errorf("dest size: got %d, want %d", statResult.Size, len(content))
	}
}

func TestIntegration_UnlinkAndCleanup(t *testing.T) {
	w := startWorker(t)
	tmpDir := t.TempDir()

	// Create nested directory structure with a single file.
	nested := filepath.Join(tmpDir, "a", "b", "c")
	os.MkdirAll(nested, 0755)
	filePath := filepath.Join(nested, "target.txt")
	writeFile(t, filePath, "delete me")

	// Unlink the file.
	resp := w.sendRequest(t, 1, "unlink_path", map[string]any{
		"path": filePath,
	})
	if !resp.OK {
		t.Fatalf("unlink_path failed: %v", resp.Error)
	}

	// Verify file is gone.
	existsResp := w.sendRequest(t, 2, "path_exists", map[string]any{
		"path": filePath,
	})
	if !existsResp.OK {
		t.Fatalf("path_exists failed: %v", existsResp.Error)
	}
	var existsResult struct {
		Exists bool `json:"exists"`
	}
	if err := json.Unmarshal(existsResp.Result, &existsResult); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if existsResult.Exists {
		t.Error("file still exists after unlink")
	}

	// Remove empty dirs from the nested path up to tmpDir.
	cleanResp := w.sendRequest(t, 3, "remove_empty_dirs", map[string]any{
		"path":    nested,
		"stop_at": tmpDir,
	})
	if !cleanResp.OK {
		t.Fatalf("remove_empty_dirs failed: %v", cleanResp.Error)
	}

	var cleanResult struct {
		Removed []string `json:"removed"`
	}
	if err := json.Unmarshal(cleanResp.Result, &cleanResult); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	// Should have removed c, b, a (3 directories).
	if len(cleanResult.Removed) != 3 {
		t.Errorf("removed %d dirs, want 3: %v", len(cleanResult.Removed), cleanResult.Removed)
	}

	// Verify the directories are gone.
	for _, dir := range []string{
		filepath.Join(tmpDir, "a", "b", "c"),
		filepath.Join(tmpDir, "a", "b"),
		filepath.Join(tmpDir, "a"),
	} {
		if _, err := os.Stat(dir); !os.IsNotExist(err) {
			t.Errorf("directory still exists: %s", dir)
		}
	}
}

func TestIntegration_UnknownOp(t *testing.T) {
	w := startWorker(t)

	resp := w.sendRequest(t, 42, "frobnicate", map[string]any{
		"x": 1,
	})

	if resp.OK {
		t.Fatal("expected error for unknown op, got ok=true")
	}
	if resp.Error == nil {
		t.Fatal("expected error detail, got nil")
	}
	if resp.Error.Kind != "unknown" {
		t.Errorf("error kind: got %q, want %q", resp.Error.Kind, "unknown")
	}
	if resp.ID != 42 {
		t.Errorf("response id: got %d, want 42", resp.ID)
	}
}

func TestIntegration_MalformedJSON(t *testing.T) {
	w := startWorker(t)

	resp := w.sendRawLine(t, "{this is not valid json")

	if resp.OK {
		t.Fatal("expected error for malformed JSON, got ok=true")
	}
	if resp.ID != -1 {
		t.Errorf("response id: got %d, want -1", resp.ID)
	}
	if resp.Error == nil {
		t.Fatal("expected error detail, got nil")
	}
	if resp.Error.Kind != "unknown" {
		t.Errorf("error kind: got %q, want %q", resp.Error.Kind, "unknown")
	}
}

func TestIntegration_CheckMount(t *testing.T) {
	w := startWorker(t)

	resp := w.sendRequest(t, 1, "check_mount", map[string]any{
		"path":            os.TempDir(),
		"timeout_seconds": 5,
	})

	if !resp.OK {
		t.Fatalf("check_mount failed: %v", resp.Error)
	}

	var mountResult struct {
		Available bool   `json:"available"`
		Error     string `json:"error,omitempty"`
	}
	if err := json.Unmarshal(resp.Result, &mountResult); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if !mountResult.Available {
		t.Errorf("check_mount: expected available=true for %s, got false (error: %s)",
			os.TempDir(), mountResult.Error)
	}
}

// --- helpers ---

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("writeFile %s: %v", path, err)
	}
}

func md5hex(s string) string {
	h := md5.Sum([]byte(s))
	return hex.EncodeToString(h[:])
}
