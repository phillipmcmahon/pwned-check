package pamhelper

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	ExitAllow  = 0
	ExitReject = 1
	ExitUsage  = 2

	defaultMaxTokenBytes      = 4096
	maxConfigurableTokenBytes = 1 << 20
)

var Version = "0.1.0"

type Helper struct {
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
}

func (h Helper) Run(args []string) int {
	stdin := h.Stdin
	stdout := h.Stdout
	stderr := h.Stderr
	if stdin == nil {
		stdin = os.Stdin
	}
	if stdout == nil {
		stdout = os.Stdout
	}
	if stderr == nil {
		stderr = os.Stderr
	}

	flags := flag.NewFlagSet("pwned-check-pam-helper", flag.ContinueOnError)
	flags.SetOutput(stderr)
	checker := flags.String("checker", "/usr/local/bin/pwned-check", "path to pwned-check binary")
	timeout := flags.Duration("timeout", 3*time.Second, "maximum checker runtime")
	maxBytes := flags.Int("max-bytes", defaultMaxTokenBytes, "maximum token size in bytes")
	versionMode := flags.Bool("version", false, "print version")
	if err := flags.Parse(args); err != nil {
		return ExitUsage
	}
	if *versionMode {
		fmt.Fprintf(stdout, "pwned-check-pam-helper %s\n", Version)
		return ExitAllow
	}
	if *checker == "" {
		fmt.Fprintln(stderr, "missing checker path")
		return ExitUsage
	}
	if *timeout <= 0 {
		fmt.Fprintln(stderr, "timeout must be greater than zero")
		return ExitUsage
	}
	if *maxBytes <= 0 {
		fmt.Fprintln(stderr, "max-bytes must be greater than zero")
		return ExitUsage
	}
	if *maxBytes > maxConfigurableTokenBytes {
		fmt.Fprintf(stderr, "max-bytes must be less than or equal to %d\n", maxConfigurableTokenBytes)
		return ExitUsage
	}

	password, err := readToken(stdin, *maxBytes)
	if err != nil {
		fmt.Fprintf(stderr, "event=pam_helper_failure reason=read_token error=%q\n", err)
		return ExitUsage
	}
	if password == "" {
		fmt.Fprintln(stderr, "event=pam_helper_failure reason=empty_token")
		return ExitUsage
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, *checker, "--stdin")
	cmd.Stdin = strings.NewReader(password + "\n")
	var checkerStderr bytes.Buffer
	cmd.Stdout = io.Discard
	cmd.Stderr = &checkerStderr

	err = cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		fmt.Fprintf(stderr, "event=pam_helper_failure reason=timeout timeout=%s\n", timeout.String())
		return ExitReject
	}
	if err == nil {
		fmt.Fprintln(stderr, "event=pam_helper_result result=allow")
		return ExitAllow
	}

	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		fmt.Fprintf(stderr, "event=pam_helper_failure reason=exec error=%q\n", err)
		return ExitReject
	}

	switch exitErr.ExitCode() {
	case 1:
		fmt.Fprintln(stderr, "event=pam_helper_result result=reject reason=pwned")
		return ExitReject
	case 2:
		fmt.Fprintf(stderr, "event=pam_helper_failure reason=checker_config%s\n", checkerStderrField(checkerStderr.String()))
		return ExitReject
	case 3:
		fmt.Fprintf(stderr, "event=pam_helper_failure reason=checker_provider%s\n", checkerStderrField(checkerStderr.String()))
		return ExitReject
	default:
		fmt.Fprintf(stderr, "event=pam_helper_failure reason=checker_exit code=%d%s\n", exitErr.ExitCode(), checkerStderrField(checkerStderr.String()))
		return ExitReject
	}
}

func checkerStderrField(value string) string {
	const maxCheckerStderrBytes = 256

	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	if len(value) > maxCheckerStderrBytes {
		value = value[:maxCheckerStderrBytes]
	}
	return fmt.Sprintf(" checker_stderr=%q", value)
}

func readToken(reader io.Reader, maxTokenBytes int) (string, error) {
	limited := io.LimitReader(reader, int64(maxTokenBytes)+1)
	data, err := io.ReadAll(limited)
	if err != nil {
		return "", err
	}
	if len(data) > maxTokenBytes {
		return "", fmt.Errorf("token exceeds %d bytes", maxTokenBytes)
	}
	return strings.TrimRight(string(data), "\r\n"), nil
}
