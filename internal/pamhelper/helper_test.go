package pamhelper

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestHelperAllowsCleanPassword(t *testing.T) {
	checker := fakeChecker(t, "exit 0")

	var stderr bytes.Buffer
	code := Helper{
		Stdin:  strings.NewReader("clean-password\n"),
		Stderr: &stderr,
	}.Run([]string{"--checker", checker, "--timeout", "1s"})

	if code != ExitAllow {
		t.Fatalf("code = %d, want %d; stderr=%s", code, ExitAllow, stderr.String())
	}
	if !strings.Contains(stderr.String(), "event=pam_helper_result result=allow") {
		t.Fatalf("stderr = %q, want allow event", stderr.String())
	}
	if strings.Contains(stderr.String(), "clean-password") {
		t.Fatalf("stderr leaked password: %q", stderr.String())
	}
}

func TestHelperRejectsPwnedPassword(t *testing.T) {
	checker := fakeChecker(t, "exit 1")

	var stderr bytes.Buffer
	code := Helper{
		Stdin:  strings.NewReader("password\n"),
		Stderr: &stderr,
	}.Run([]string{"--checker", checker, "--timeout", "1s"})

	if code != ExitReject {
		t.Fatalf("code = %d, want %d; stderr=%s", code, ExitReject, stderr.String())
	}
	if !strings.Contains(stderr.String(), "event=pam_helper_result result=reject reason=pwned") {
		t.Fatalf("stderr = %q, want pwned reject event", stderr.String())
	}
	if strings.Contains(stderr.String(), "password") {
		t.Fatalf("stderr leaked password: %q", stderr.String())
	}
}

func TestHelperRejectsCheckerProviderFailure(t *testing.T) {
	checker := fakeChecker(t, "exit 3")

	var stderr bytes.Buffer
	code := Helper{
		Stdin:  strings.NewReader("candidate\n"),
		Stderr: &stderr,
	}.Run([]string{"--checker", checker, "--timeout", "1s"})

	if code != ExitReject {
		t.Fatalf("code = %d, want %d", code, ExitReject)
	}
	if !strings.Contains(stderr.String(), "reason=checker_provider") {
		t.Fatalf("stderr = %q, want provider failure", stderr.String())
	}
}

func TestHelperRejectsTimeout(t *testing.T) {
	checker := fakeChecker(t, "sleep 1\nexit 0")

	var stderr bytes.Buffer
	code := Helper{
		Stdin:  strings.NewReader("candidate\n"),
		Stderr: &stderr,
	}.Run([]string{"--checker", checker, "--timeout", "10ms"})

	if code != ExitReject {
		t.Fatalf("code = %d, want %d", code, ExitReject)
	}
	if !strings.Contains(stderr.String(), "reason=timeout") {
		t.Fatalf("stderr = %q, want timeout failure", stderr.String())
	}
}

func TestHelperRequiresToken(t *testing.T) {
	checker := fakeChecker(t, "exit 0")

	var stderr bytes.Buffer
	code := Helper{
		Stdin:  strings.NewReader("\n"),
		Stderr: &stderr,
	}.Run([]string{"--checker", checker, "--timeout", "1s"})

	if code != ExitUsage {
		t.Fatalf("code = %d, want %d", code, ExitUsage)
	}
}

func TestHelperRejectsInvalidTimeout(t *testing.T) {
	var stderr bytes.Buffer
	code := Helper{
		Stdin:  strings.NewReader("candidate\n"),
		Stderr: &stderr,
	}.Run([]string{"--checker", "/bin/true", "--timeout", "0s"})

	if code != ExitUsage {
		t.Fatalf("code = %d, want %d", code, ExitUsage)
	}
}

func TestHelperVersion(t *testing.T) {
	var stdout bytes.Buffer
	code := Helper{Stdout: &stdout}.Run([]string{"--version"})
	if code != ExitAllow {
		t.Fatalf("code = %d, want %d", code, ExitAllow)
	}
	if stdout.String() != "pwned-check-pam-helper 0.1.0\n" {
		t.Fatalf("stdout = %q", stdout.String())
	}
}

func fakeChecker(t *testing.T, body string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell fake checker is POSIX-only")
	}

	path := filepath.Join(t.TempDir(), "checker")
	content := "#!/bin/sh\ncat >/dev/null\n" + body + "\n"
	if err := os.WriteFile(path, []byte(content), 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}
