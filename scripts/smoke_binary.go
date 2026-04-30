package main

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
)

func main() {
	binary := "./dist/pwned-check"
	if len(os.Args) > 1 {
		binary = os.Args[1]
	}

	prefix, suffix := hashParts("password")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/range/"+prefix {
			http.NotFound(w, r)
			return
		}
		_, _ = fmt.Fprintf(w, "%s:123\n", suffix)
	}))
	defer server.Close()

	cmd := exec.Command(binary, "--stdin")
	cmd.Stdin = strings.NewReader("password\n")
	cmd.Env = append(os.Environ(),
		"PWNED_CHECK_PROVIDER=local",
		"PWNED_CHECK_LOCAL_URL="+server.URL,
	)
	output, err := cmd.CombinedOutput()
	if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
		text := string(output)
		if !strings.Contains(text, "prefix=5BAA6 pwned=true count=123") {
			fail("expected mocked pwned result, got:\n%s", text)
		}
		if strings.Contains(text, "password") {
			fail("password leaked to output:\n%s", text)
		}
		return
	}
	if err != nil {
		fail("expected exit 1, got %v:\n%s", err, string(output))
	}
	fail("expected exit 1, got 0:\n%s", string(output))
}

func hashParts(password string) (string, string) {
	sum := sha1.Sum([]byte(password))
	digest := strings.ToUpper(hex.EncodeToString(sum[:]))
	return digest[:5], digest[5:]
}

func fail(format string, args ...any) {
	_, _ = fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
