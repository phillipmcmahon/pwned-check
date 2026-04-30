package pwned

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"strings"
)

var Version = "0.2.0"

const (
	ExitClean        = 0
	ExitPwned        = 1
	ExitConfig       = 2
	ExitNetworkError = 3
)

type CLI struct {
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
}

func (c CLI) Run(args []string) int {
	stdin := c.Stdin
	stdout := c.Stdout
	stderr := c.Stderr
	if stdin == nil {
		stdin = os.Stdin
	}
	if stdout == nil {
		stdout = os.Stdout
	}
	if stderr == nil {
		stderr = os.Stderr
	}

	flags := flag.NewFlagSet("pwned-check", flag.ContinueOnError)
	flags.SetOutput(stderr)
	stdinMode := flags.Bool("stdin", false, "read password from stdin")
	versionMode := flags.Bool("version", false, "print version")
	if err := flags.Parse(args); err != nil {
		return ExitConfig
	}
	if *versionMode {
		fmt.Fprintf(stdout, "pwned-check %s\n", Version)
		return ExitClean
	}
	if !*stdinMode {
		fmt.Fprintln(stderr, "--stdin is required")
		return ExitConfig
	}

	cfg, err := LoadConfig()
	if err != nil {
		fmt.Fprintln(stderr, err)
		return ExitConfig
	}

	password, err := readPassword(stdin)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return ExitConfig
	}
	if password == "" {
		fmt.Fprintln(stderr, "empty password")
		return ExitConfig
	}

	provider := NewHIBPProvider(cfg.HIBPEndpoint, cfg.Timeout)
	if cfg.Provider == "local" {
		provider = NewLocalProvider(cfg.LocalURL, cfg.Timeout)
	}

	logger := log.New(stderr, "", log.LstdFlags)
	result, err := Validate(password, provider)
	if err != nil {
		if cfg.FailClosed {
			logger.Printf("event=provider_failure fail_closed=true error=%q", err)
			return ExitNetworkError
		}
		logger.Printf("event=provider_failure fail_closed=false error=%q", err)
		return ExitClean
	}

	logger.Printf("event=validation prefix=%s pwned=%t count=%d", result.Prefix, result.Pwned, result.Count)
	if result.Pwned {
		return ExitPwned
	}
	return ExitClean
}

func readPassword(reader io.Reader) (string, error) {
	line, err := bufio.NewReader(reader).ReadString('\n')
	if err != nil && err != io.EOF {
		return "", err
	}
	return strings.TrimRight(line, "\r\n"), nil
}
