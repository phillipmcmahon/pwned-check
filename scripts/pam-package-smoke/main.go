package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	serviceName = "pwned-check-smoke"
	smokeUser   = "root"
)

func main() {
	if len(os.Args) != 2 {
		fail("usage: pam-package-smoke <linux-package.tar.gz>")
	}

	workspace, err := os.MkdirTemp("", "pwned-check-pam-package-smoke-*")
	if err != nil {
		fail("create workspace: %v", err)
	}
	defer os.RemoveAll(workspace)

	packageDir := extractPackage(os.Args[1], workspace)
	installPackage(packageDir)
	checkInstalledBinaries()
	writeCheckerWrapper()
	writePAMService()
	pamClient := ""
	if _, err := exec.LookPath("pamtester"); err != nil {
		pamClient = buildPAMClient(workspace)
	}
	printSmokeContext(pamClient)
	serverURL, stopServer := startHIBPMock()
	defer stopServer()

	tests := []pamCase{
		{name: "clean available fail-open", password: "candidate", localURL: serverURL, failClosed: false, wantAllow: true},
		{name: "clean available fail-closed", password: "candidate", localURL: serverURL, failClosed: true, wantAllow: true},
		{name: "pwned available fail-open", password: "password", localURL: serverURL, failClosed: false, wantAllow: false},
		{name: "pwned available fail-closed", password: "password", localURL: serverURL, failClosed: true, wantAllow: false},
		{name: "clean unavailable fail-open", password: "candidate", localURL: "http://127.0.0.1:9", failClosed: false, wantAllow: true},
		{name: "pwned unavailable fail-open", password: "password", localURL: "http://127.0.0.1:9", failClosed: false, wantAllow: true},
		{name: "clean unavailable fail-closed", password: "candidate", localURL: "http://127.0.0.1:9", failClosed: true, wantAllow: false},
		{name: "pwned unavailable fail-closed", password: "password", localURL: "http://127.0.0.1:9", failClosed: true, wantAllow: false},
		{name: "empty token", password: "", localURL: serverURL, failClosed: false, wantAllow: false},
		{name: "checker timeout", password: "candidate", localURL: serverURL, failClosed: false, checkerSleep: "2", wantAllow: false},
		{name: "checker config error", password: "candidate", localURL: serverURL, failClosed: false, provider: "invalid", wantAllow: false},
	}

	for _, tc := range tests {
		runPAMCase(pamClient, tc)
	}

	fmt.Println("PAM package smoke passed")
}

type pamCase struct {
	name         string
	password     string
	localURL     string
	failClosed   bool
	checkerSleep string
	provider     string
	wantAllow    bool
}

func extractPackage(packagePath, workspace string) string {
	file, err := os.Open(packagePath)
	if err != nil {
		fail("open package: %v", err)
	}
	defer file.Close()

	gzipReader, err := gzip.NewReader(file)
	if err != nil {
		fail("open gzip package: %v", err)
	}
	defer gzipReader.Close()

	tarReader := tar.NewReader(gzipReader)
	var rootName string
	for {
		header, err := tarReader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			fail("read package tar: %v", err)
		}
		name := filepath.Clean(header.Name)
		if strings.HasPrefix(name, "..") || filepath.IsAbs(name) {
			fail("unsafe package path: %s", header.Name)
		}
		parts := strings.Split(name, string(os.PathSeparator))
		if rootName == "" {
			rootName = parts[0]
		}
		if rootName != parts[0] {
			fail("package contains multiple roots: %s and %s", rootName, parts[0])
		}

		target := filepath.Join(workspace, name)
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				fail("create directory %s: %v", target, err)
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				fail("create parent directory %s: %v", filepath.Dir(target), err)
			}
			out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(header.Mode))
			if err != nil {
				fail("create file %s: %v", target, err)
			}
			if _, err := io.Copy(out, tarReader); err != nil {
				_ = out.Close()
				fail("extract file %s: %v", target, err)
			}
			if err := out.Close(); err != nil {
				fail("close file %s: %v", target, err)
			}
		default:
			fail("unsupported package entry type %d for %s", header.Typeflag, header.Name)
		}
	}
	if rootName == "" {
		fail("package is empty")
	}
	return filepath.Join(workspace, rootName)
}

func installPackage(packageDir string) {
	cmd := exec.Command("./install.sh")
	cmd.Dir = packageDir
	run("install package", cmd, nil)
}

func checkInstalledBinaries() {
	checkVersion("/usr/local/bin/pwned-check", "pwned-check ")
	checkVersion("/usr/local/bin/pwned-check-pam-helper", "pwned-check-pam-helper ")

	for _, path := range []string{
		"/usr/local/lib/pwned-check/current",
		"/usr/local/lib/pwned-check/current-pam-helper",
	} {
		target, err := os.Readlink(path)
		if err != nil {
			fail("expected install symlink %s: %v", path, err)
		}
		if target == "" {
			fail("install symlink %s has empty target", path)
		}
	}
}

func checkVersion(binary, prefix string) {
	output := run("version "+binary, exec.Command(binary, "--version"), nil)
	if !strings.HasPrefix(output, prefix) {
		fail("%s --version output = %q, want prefix %q", binary, output, prefix)
	}
}

func writeCheckerWrapper() {
	wrapper := `#!/bin/sh
set -eu
. /tmp/pwned-check-smoke.env
export PWNED_CHECK_PROVIDER
export PWNED_CHECK_LOCAL_URL
export PWNED_CHECK_FAIL_CLOSED
export PWNED_CHECK_TIMEOUT
if [ -n "${PWNED_CHECK_SMOKE_SLEEP:-}" ]; then
  sleep "${PWNED_CHECK_SMOKE_SLEEP}"
fi
exec /usr/local/bin/pwned-check "$@"
`
	if err := os.WriteFile("/usr/local/bin/pwned-check-smoke-checker", []byte(wrapper), 0o755); err != nil {
		fail("write checker wrapper: %v", err)
	}
}

func writePAMService() {
	service := "auth requisite pam_exec.so expose_authtok quiet /usr/local/bin/pwned-check-pam-helper --checker /usr/local/bin/pwned-check-smoke-checker --timeout 1s\n" +
		"auth required pam_permit.so\n"
	path := "/etc/pam.d/" + serviceName
	if err := os.WriteFile(path, []byte(service), 0o644); err != nil {
		fail("write PAM service %s: %v", path, err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		fail("read PAM service %s: %v", path, err)
	}
	text := string(data)
	for _, want := range []string{"pam_exec.so", "expose_authtok", "/usr/local/bin/pwned-check-pam-helper", "/usr/local/bin/pwned-check-smoke-checker", "pam_permit.so"} {
		if !strings.Contains(text, want) {
			fail("PAM service %s is missing %q:\n%s", path, want, text)
		}
	}
}

func printSmokeContext(pamClient string) {
	client := "pamtester"
	if pamClient != "" {
		client = "compiled fallback PAM client"
	}

	fmt.Printf("PAM package smoke environment: client=%s\n", client)
	if osRelease, err := os.ReadFile("/etc/os-release"); err == nil {
		for _, line := range strings.Split(string(osRelease), "\n") {
			if strings.HasPrefix(line, "PRETTY_NAME=") {
				fmt.Printf("PAM package smoke environment: %s\n", line)
				break
			}
		}
	}
	if data, err := os.ReadFile("/etc/pam.d/" + serviceName); err == nil {
		fmt.Printf("PAM package smoke service:\n%s", data)
	}
}

func buildPAMClient(workspace string) string {
	sourcePath := filepath.Join(workspace, "pam-smoke-client.c")
	binaryPath := filepath.Join(workspace, "pam-smoke-client")
	source := `#define _GNU_SOURCE
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *candidate;

static int smoke_conv(int num_msg, const struct pam_message **msg, struct pam_response **resp, void *appdata_ptr) {
  (void)appdata_ptr;
  struct pam_response *responses = calloc((size_t)num_msg, sizeof(struct pam_response));
  if (responses == NULL) {
    return PAM_BUF_ERR;
  }
  for (int i = 0; i < num_msg; i++) {
    switch (msg[i]->msg_style) {
    case PAM_PROMPT_ECHO_OFF:
    case PAM_PROMPT_ECHO_ON:
      responses[i].resp = strdup(candidate);
      if (responses[i].resp == NULL) {
        free(responses);
        return PAM_BUF_ERR;
      }
      break;
    case PAM_TEXT_INFO:
    case PAM_ERROR_MSG:
      responses[i].resp = NULL;
      break;
    default:
      free(responses);
      return PAM_CONV_ERR;
    }
  }
  *resp = responses;
  return PAM_SUCCESS;
}

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: %s <service> <user> <password>\n", argv[0]);
    return 2;
  }
  candidate = argv[3];
  struct pam_conv conv = {smoke_conv, NULL};
  pam_handle_t *pamh = NULL;
  int rc = pam_start(argv[1], argv[2], &conv, &pamh);
  if (rc != PAM_SUCCESS) {
    fprintf(stderr, "pam_start: %s\n", pam_strerror(pamh, rc));
    return 2;
  }
  pam_set_item(pamh, PAM_AUTHTOK, candidate);
  rc = pam_authenticate(pamh, PAM_SILENT);
  if (rc != PAM_SUCCESS) {
    fprintf(stderr, "pam_authenticate: %s\n", pam_strerror(pamh, rc));
  }
  int end_rc = pam_end(pamh, rc);
  if (end_rc != PAM_SUCCESS) {
    fprintf(stderr, "pam_end: %d\n", end_rc);
    return 2;
  }
  return rc == PAM_SUCCESS ? 0 : 1;
}
`
	if err := os.WriteFile(sourcePath, []byte(source), 0o644); err != nil {
		fail("write PAM client source: %v", err)
	}
	run("compile PAM client", exec.Command("cc", "-Wall", "-Wextra", "-Werror", "-o", binaryPath, sourcePath, "-lpam"), nil)
	return binaryPath
}

func startHIBPMock() (string, func()) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fail("start mock listener: %v", err)
	}

	pwnedPrefix, pwnedSuffix := hashParts("password")
	server := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/range/"+pwnedPrefix {
				w.WriteHeader(http.StatusOK)
				_, _ = fmt.Fprint(w, "00000000000000000000000000000000000:1\n")
				return
			}
			_, _ = fmt.Fprintf(w, "%s:123\n", pwnedSuffix)
		}),
	}

	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			fail("mock server failed: %v", err)
		}
	}()

	stop := func() {
		_ = server.Close()
	}
	return "http://" + listener.Addr().String(), stop
}

func runPAMCase(pamClient string, tc pamCase) {
	provider := tc.provider
	if provider == "" {
		provider = "local"
	}

	env := []string{
		"PWNED_CHECK_PROVIDER=" + provider,
		"PWNED_CHECK_LOCAL_URL=" + tc.localURL,
		"PWNED_CHECK_FAIL_CLOSED=" + boolString(tc.failClosed),
		"PWNED_CHECK_TIMEOUT=0.5",
		"PWNED_CHECK_SMOKE_SLEEP=" + tc.checkerSleep,
	}
	if err := os.WriteFile("/tmp/pwned-check-smoke.env", []byte(strings.Join(env, "\n")+"\n"), 0o600); err != nil {
		fail("%s: write checker env: %v", tc.name, err)
	}

	var cmd *exec.Cmd
	if pamClient == "" {
		cmd = exec.Command("pamtester", serviceName, smokeUser, "authenticate")
		cmd.Stdin = strings.NewReader(tc.password + "\n")
	} else {
		cmd = exec.Command(pamClient, serviceName, smokeUser, tc.password)
	}
	output, err := cmd.CombinedOutput()
	allowed := err == nil
	if allowed != tc.wantAllow {
		fail("%s: allow=%t, want %t, err=%v\n%s", tc.name, allowed, tc.wantAllow, err, output)
	}
	fmt.Printf("PAM case passed: %s\n", tc.name)
}

func run(label string, cmd *exec.Cmd, stdin io.Reader) string {
	if stdin != nil {
		cmd.Stdin = stdin
	}
	output, err := cmd.CombinedOutput()
	if err != nil {
		fail("%s failed: %v\n%s", label, err, output)
	}
	return string(output)
}

func hashParts(password string) (string, string) {
	sum := sha1.Sum([]byte(password))
	digest := strings.ToUpper(hex.EncodeToString(sum[:]))
	return digest[:5], digest[5:]
}

func boolString(value bool) string {
	if value {
		return "true"
	}
	return "false"
}

func fail(format string, args ...any) {
	_, _ = fmt.Fprintf(os.Stderr, format+"\n", args...)
	time.Sleep(10 * time.Millisecond)
	os.Exit(1)
}
