package ops

import (
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/jeffdc/grove/protocol"
)

// ---------- hash_path ----------

func TestHashPath_KnownContent(t *testing.T) {
	tmp := filepath.Join(t.TempDir(), "known.txt")
	content := []byte("hello world\n")
	if err := os.WriteFile(tmp, content, 0644); err != nil {
		t.Fatal(err)
	}

	req := makeRequest(t, 1, "hash_path", hashPathArgs{Path: tmp})
	resp := HashPath(req)

	if !resp.OK {
		t.Fatalf("expected OK response, got error: %+v", resp.Error)
	}

	var result hashResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	if result.Path != tmp {
		t.Errorf("path: got %q, want %q", result.Path, tmp)
	}

	// MD5 of "hello world\n" (12 bytes).
	const want = "6f5902ac237024bdd0c176cb93063dc4"
	if result.MD5 != want {
		t.Errorf("md5: got %q, want %q", result.MD5, want)
	}
}

func TestHashPath_MissingFile(t *testing.T) {
	req := makeRequest(t, 2, "hash_path", hashPathArgs{Path: "/no/such/path/ever"})
	resp := HashPath(req)

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

func TestHashPath_EmptyFile(t *testing.T) {
	tmp := filepath.Join(t.TempDir(), "empty.txt")
	if err := os.WriteFile(tmp, []byte{}, 0644); err != nil {
		t.Fatal(err)
	}

	req := makeRequest(t, 3, "hash_path", hashPathArgs{Path: tmp})
	resp := HashPath(req)

	if !resp.OK {
		t.Fatalf("expected OK response, got error: %+v", resp.Error)
	}

	var result hashResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	// MD5 of empty input.
	const want = "d41d8cd98f00b204e9800998ecf8427e"
	if result.MD5 != want {
		t.Errorf("md5: got %q, want %q", result.MD5, want)
	}
}

// ---------- hash_paths (batch) ----------

func TestHashPaths_Mixed(t *testing.T) {
	dir := t.TempDir()

	fileA := filepath.Join(dir, "a.txt")
	fileB := filepath.Join(dir, "b.txt")
	fileC := filepath.Join(dir, "c.txt") // will not exist

	if err := os.WriteFile(fileA, []byte("aaa"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fileB, []byte("bbb"), 0644); err != nil {
		t.Fatal(err)
	}

	req := makeRequest(t, 4, "hash_paths", hashPathsArgs{Paths: []string{fileA, fileB, fileC}})
	resp := HashPaths(req)

	if !resp.OK {
		t.Fatalf("expected OK response, got error: %+v", resp.Error)
	}

	var result hashPathsResult
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

	// Verify the successful results contain the right paths and valid hashes.
	paths := map[string]string{}
	for _, r := range result.Results {
		paths[r.Path] = r.MD5
	}
	if _, ok := paths[fileA]; !ok {
		t.Errorf("missing result for %s", fileA)
	}
	if _, ok := paths[fileB]; !ok {
		t.Errorf("missing result for %s", fileB)
	}

	// Verify actual hash values.
	hashA := md5.Sum([]byte("aaa"))
	wantA := hex.EncodeToString(hashA[:])
	if paths[fileA] != wantA {
		t.Errorf("fileA md5: got %q, want %q", paths[fileA], wantA)
	}

	hashB := md5.Sum([]byte("bbb"))
	wantB := hex.EncodeToString(hashB[:])
	if paths[fileB] != wantB {
		t.Errorf("fileB md5: got %q, want %q", paths[fileB], wantB)
	}
}

func TestHashPaths_LargeFile(t *testing.T) {
	tmp := filepath.Join(t.TempDir(), "large.bin")

	// 64 KB of repeated 0xAB bytes — larger than the 8KB read chunk.
	data := make([]byte, 64*1024)
	for i := range data {
		data[i] = 0xAB
	}
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		t.Fatal(err)
	}

	req := makeRequest(t, 5, "hash_paths", hashPathsArgs{Paths: []string{tmp}})
	resp := HashPaths(req)

	if !resp.OK {
		t.Fatalf("expected OK response, got error: %+v", resp.Error)
	}

	var result hashPathsResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	if len(result.Results) != 1 {
		t.Fatalf("results count: got %d, want 1", len(result.Results))
	}
	if len(result.Errors) != 0 {
		t.Errorf("errors count: got %d, want 0", len(result.Errors))
	}

	// Compute expected hash the same way the implementation should.
	h := md5.Sum(data)
	want := hex.EncodeToString(h[:])
	if result.Results[0].MD5 != want {
		t.Errorf("large file md5: got %q, want %q", result.Results[0].MD5, want)
	}
}
