package pwned

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestCLIRejectsPwnedPasswordWithMockedRangeService(t *testing.T) {
	prefix, suffix := HashParts("password")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/range/"+prefix {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = w.Write([]byte(suffix + ":123\n"))
	}))
	defer server.Close()

	t.Setenv("PWNED_CHECK_PROVIDER", "local")
	t.Setenv("PWNED_CHECK_LOCAL_URL", server.URL)

	var stderr bytes.Buffer
	code := CLI{
		Stdin:  strings.NewReader("password\n"),
		Stderr: &stderr,
	}.Run([]string{"--stdin"})

	if code != ExitPwned {
		t.Fatalf("code = %d, want %d; stderr=%s", code, ExitPwned, stderr.String())
	}
	if !strings.Contains(stderr.String(), "event=validation prefix=5BAA6 pwned=true count=123") {
		t.Fatalf("stderr = %q, want mocked pwned result", stderr.String())
	}
	if strings.Contains(stderr.String(), "password") {
		t.Fatalf("stderr leaked password: %q", stderr.String())
	}
}

func TestCLIFailOpen(t *testing.T) {
	t.Setenv("PWNED_CHECK_PROVIDER", "local")
	t.Setenv("PWNED_CHECK_LOCAL_URL", "http://127.0.0.1:9")
	t.Setenv("PWNED_CHECK_FAIL_CLOSED", "false")

	var stderr bytes.Buffer
	code := CLI{
		Stdin:  strings.NewReader("password\n"),
		Stderr: &stderr,
	}.Run([]string{"--stdin"})
	if code != ExitClean {
		t.Fatalf("code = %d, want %d", code, ExitClean)
	}
	if !strings.Contains(stderr.String(), "event=provider_failure fail_closed=false") {
		t.Fatalf("stderr = %q, want fail-open provider failure event", stderr.String())
	}
}

func TestCLIFailClosed(t *testing.T) {
	t.Setenv("PWNED_CHECK_PROVIDER", "local")
	t.Setenv("PWNED_CHECK_LOCAL_URL", "http://127.0.0.1:9")
	t.Setenv("PWNED_CHECK_FAIL_CLOSED", "true")

	var stderr bytes.Buffer
	code := CLI{
		Stdin:  strings.NewReader("password\n"),
		Stderr: &stderr,
	}.Run([]string{"--stdin"})
	if code != ExitNetworkError {
		t.Fatalf("code = %d, want %d", code, ExitNetworkError)
	}
	if !strings.Contains(stderr.String(), "event=provider_failure fail_closed=true") {
		t.Fatalf("stderr = %q, want fail-closed provider failure event", stderr.String())
	}
}

func TestCLIVersion(t *testing.T) {
	var stdout bytes.Buffer
	code := CLI{Stdout: &stdout}.Run([]string{"--version"})
	if code != ExitClean {
		t.Fatalf("code = %d, want %d", code, ExitClean)
	}
	if stdout.String() != "pwned-check "+Version+"\n" {
		t.Fatalf("stdout = %q", stdout.String())
	}
}

func TestCLIFailClosedProviderTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
		_, _ = w.Write([]byte("unused:0\n"))
	}))
	defer server.Close()

	t.Setenv("PWNED_CHECK_PROVIDER", "local")
	t.Setenv("PWNED_CHECK_LOCAL_URL", server.URL)
	t.Setenv("PWNED_CHECK_TIMEOUT", "0.01")
	t.Setenv("PWNED_CHECK_FAIL_CLOSED", "true")

	var stderr bytes.Buffer
	code := CLI{
		Stdin:  strings.NewReader("password\n"),
		Stderr: &stderr,
	}.Run([]string{"--stdin"})
	if code != ExitNetworkError {
		t.Fatalf("code = %d, want %d", code, ExitNetworkError)
	}
}
