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
	"time"
)

func main() {
	checker := "./pwned-check"
	helper := "./pwned-check-pam-helper"
	if len(os.Args) > 1 {
		checker = os.Args[1]
	}
	if len(os.Args) > 2 {
		helper = os.Args[2]
	}

	checkVersion(checker, "pwned-check ")
	checkVersion(helper, "pwned-check-pam-helper ")
	checkerRejectsPwnedPassword(checker)
	checkerAllowsProviderFailureFailOpen(checker)
	checkerRejectsProviderFailureFailClosed(checker)
	helperAllowsCleanPassword(checker, helper)
	helperRejectsPwnedPassword(checker, helper)
	helperRejectsProviderFailureFailClosed(checker, helper)
	helperRejectsTimeout(helper)
}

func checkVersion(binary, prefix string) {
	cmd := exec.Command(binary, "--version")
	output, err := cmd.CombinedOutput()
	if err != nil {
		fail("%s --version failed: %v\n%s", binary, err, output)
	}
	if !strings.HasPrefix(string(output), prefix) {
		fail("%s --version output = %q, want prefix %q", binary, string(output), prefix)
	}
}

func checkerRejectsPwnedPassword(checker string) {
	prefix, suffix := hashParts("password")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/range/"+prefix {
			http.NotFound(w, r)
			return
		}
		_, _ = fmt.Fprintf(w, "%s:123\n", suffix)
	}))
	defer server.Close()

	cmd := exec.Command(checker, "--stdin")
	cmd.Stdin = strings.NewReader("password\n")
	cmd.Env = append(os.Environ(),
		"PWNED_CHECK_PROVIDER=hibp",
		"PWNED_CHECK_HIBP_ENDPOINT="+server.URL+"/range/",
	)
	output, err := cmd.CombinedOutput()
	if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
		text := string(output)
		if !strings.Contains(text, "event=validation prefix=5BAA6 pwned=true count=123") {
			fail("checker expected pwned result, got:\n%s", text)
		}
		if strings.Contains(text, "password") {
			fail("checker leaked password:\n%s", text)
		}
		return
	}
	if err != nil {
		fail("checker expected exit 1, got %v:\n%s", err, output)
	}
	fail("checker expected exit 1, got 0:\n%s", output)
}

func checkerAllowsProviderFailureFailOpen(checker string) {
	cmd := exec.Command(checker, "--stdin")
	cmd.Stdin = strings.NewReader("candidate\n")
	cmd.Env = append(os.Environ(),
		"PWNED_CHECK_PROVIDER=hibp",
		"PWNED_CHECK_HIBP_ENDPOINT=http://127.0.0.1:9/range/",
		"PWNED_CHECK_FAIL_CLOSED=false",
	)
	output, err := cmd.CombinedOutput()
	if err != nil {
		fail("checker fail-open expected exit 0, got %v:\n%s", err, output)
	}
	text := string(output)
	if !strings.Contains(text, "event=provider_failure fail_closed=false") {
		fail("checker fail-open expected provider failure event, got:\n%s", text)
	}
	if strings.Contains(text, "candidate") {
		fail("checker fail-open leaked candidate password:\n%s", text)
	}
}

func checkerRejectsProviderFailureFailClosed(checker string) {
	cmd := exec.Command(checker, "--stdin")
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
			fail("checker fail-closed expected provider failure event, got:\n%s", text)
		}
		if strings.Contains(text, "candidate") {
			fail("checker fail-closed leaked candidate password:\n%s", text)
		}
		return
	}
	if err != nil {
		fail("checker fail-closed expected exit 3, got %v:\n%s", err, output)
	}
	fail("checker fail-closed expected exit 3, got 0:\n%s", output)
}

func helperAllowsCleanPassword(checker, helper string) {
	cmd := exec.Command(helper, "--checker", checker, "--timeout", "3s")
	cmd.Stdin = strings.NewReader("candidate\n")
	cmd.Env = append(os.Environ(),
		"PWNED_CHECK_PROVIDER=hibp",
		"PWNED_CHECK_HIBP_ENDPOINT=http://127.0.0.1:9/range/",
		"PWNED_CHECK_FAIL_CLOSED=false",
	)
	output, err := cmd.CombinedOutput()
	if err != nil {
		fail("helper expected allow exit 0, got %v:\n%s", err, output)
	}
	text := string(output)
	if !strings.Contains(text, "event=pam_helper_result result=allow") {
		fail("helper expected allow event, got:\n%s", text)
	}
	if strings.Contains(text, "candidate") {
		fail("helper leaked candidate password:\n%s", text)
	}
}

func helperRejectsPwnedPassword(checker, helper string) {
	prefix, suffix := hashParts("password")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/range/"+prefix {
			http.NotFound(w, r)
			return
		}
		_, _ = fmt.Fprintf(w, "%s:123\n", suffix)
	}))
	defer server.Close()

	cmd := exec.Command(helper, "--checker", checker, "--timeout", "3s")
	cmd.Stdin = strings.NewReader("password\n")
	cmd.Env = append(os.Environ(),
		"PWNED_CHECK_PROVIDER=hibp",
		"PWNED_CHECK_HIBP_ENDPOINT="+server.URL+"/range/",
	)
	output, err := cmd.CombinedOutput()
	if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
		text := string(output)
		if !strings.Contains(text, "event=pam_helper_result result=reject reason=pwned") {
			fail("helper expected pwned reject event, got:\n%s", text)
		}
		if strings.Contains(text, "password") {
			fail("helper leaked password:\n%s", text)
		}
		return
	}
	if err != nil {
		fail("helper expected reject exit 1, got %v:\n%s", err, output)
	}
	fail("helper expected reject exit 1, got 0:\n%s", output)
}

func helperRejectsProviderFailureFailClosed(checker, helper string) {
	cmd := exec.Command(helper, "--checker", checker, "--timeout", "3s")
	cmd.Stdin = strings.NewReader("candidate\n")
	cmd.Env = append(os.Environ(),
		"PWNED_CHECK_PROVIDER=hibp",
		"PWNED_CHECK_HIBP_ENDPOINT=http://127.0.0.1:9/range/",
		"PWNED_CHECK_FAIL_CLOSED=true",
	)
	output, err := cmd.CombinedOutput()
	if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
		text := string(output)
		if !strings.Contains(text, "event=pam_helper_failure reason=checker_provider") {
			fail("helper expected provider failure reject event, got:\n%s", text)
		}
		if strings.Contains(text, "candidate") {
			fail("helper provider failure leaked candidate password:\n%s", text)
		}
		return
	}
	if err != nil {
		fail("helper expected provider failure reject exit 1, got %v:\n%s", err, output)
	}
	fail("helper expected provider failure reject exit 1, got 0:\n%s", output)
}

func helperRejectsTimeout(helper string) {
	checker, err := os.CreateTemp("", "pwned-check-timeout-*")
	if err != nil {
		fail("create timeout checker: %v", err)
	}
	defer os.Remove(checker.Name())
	if _, err := checker.WriteString("#!/bin/sh\ncat >/dev/null\nsleep 1\n"); err != nil {
		fail("write timeout checker: %v", err)
	}
	if err := checker.Close(); err != nil {
		fail("close timeout checker: %v", err)
	}
	if err := os.Chmod(checker.Name(), 0o700); err != nil {
		fail("chmod timeout checker: %v", err)
	}

	cmd := exec.Command(helper, "--checker", checker.Name(), "--timeout", "10ms")
	cmd.Stdin = strings.NewReader("candidate\n")
	output, err := cmd.CombinedOutput()
	if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
		text := string(output)
		if !strings.Contains(text, "reason=timeout") {
			fail("helper expected timeout event, got:\n%s", text)
		}
		return
	}
	if err != nil {
		fail("helper expected timeout reject exit 1, got %v:\n%s", err, output)
	}
	fail("helper expected timeout reject exit 1, got 0:\n%s", output)
}

func hashParts(password string) (string, string) {
	sum := sha1.Sum([]byte(password))
	digest := strings.ToUpper(hex.EncodeToString(sum[:]))
	return digest[:5], digest[5:]
}

func fail(format string, args ...any) {
	_, _ = fmt.Fprintf(os.Stderr, format+"\n", args...)
	time.Sleep(10 * time.Millisecond)
	os.Exit(1)
}
