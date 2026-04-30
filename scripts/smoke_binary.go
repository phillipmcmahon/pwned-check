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

	checkerRejectsPwnedPassword(binary)
	checkerAllowsProviderFailureFailOpen(binary)
	checkerRejectsProviderFailureFailClosed(binary)
}

func checkerRejectsPwnedPassword(binary string) {
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
		"PWNED_CHECK_PROVIDER=hibp",
		"PWNED_CHECK_HIBP_ENDPOINT="+server.URL+"/range/",
	)
	output, err := cmd.CombinedOutput()
	if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
		text := string(output)
		if !strings.Contains(text, "event=validation prefix=5BAA6 pwned=true count=123") {
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

func checkerAllowsProviderFailureFailOpen(binary string) {
	cmd := exec.Command(binary, "--stdin")
	cmd.Stdin = strings.NewReader("candidate\n")
	cmd.Env = append(os.Environ(),
		"PWNED_CHECK_PROVIDER=hibp",
		"PWNED_CHECK_HIBP_ENDPOINT=http://127.0.0.1:9/range/",
		"PWNED_CHECK_FAIL_CLOSED=false",
	)
	output, err := cmd.CombinedOutput()
	if err != nil {
		fail("expected fail-open exit 0, got %v:\n%s", err, output)
	}
	text := string(output)
	if !strings.Contains(text, "event=provider_failure fail_closed=false") {
		fail("expected fail-open provider failure event, got:\n%s", text)
	}
	if strings.Contains(text, "candidate") {
		fail("fail-open output leaked candidate password:\n%s", text)
	}
}

func checkerRejectsProviderFailureFailClosed(binary string) {
	cmd := exec.Command(binary, "--stdin")
	cmd.Stdin = strings.NewReader("candidate\n")
	cmd.Env = append(os.Environ(),
		"PWNED_CHECK_PROVIDER=hibp",
		"PWNED_CHECK_HIBP_ENDPOINT=http://127.0.0.1:9/range/",
		"PWNED_CHECK_FAIL_CLOSED=true",
	)
	output, err := cmd.CombinedOutput()
	if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 3 {
		text := string(output)
		if !strings.Contains(text, "event=provider_failure fail_closed=true") {
			fail("expected fail-closed provider failure event, got:\n%s", text)
		}
		if strings.Contains(text, "candidate") {
			fail("fail-closed output leaked candidate password:\n%s", text)
		}
		return
	}
	if err != nil {
		fail("expected fail-closed exit 3, got %v:\n%s", err, output)
	}
	fail("expected fail-closed exit 3, got 0:\n%s", output)
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
