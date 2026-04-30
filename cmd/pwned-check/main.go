package main

import (
	"os"

	"github.com/phillipmcmahon/pwned-check/internal/pwned"
)

func main() {
	cli := pwned.CLI{
		Stdin:  os.Stdin,
		Stdout: os.Stdout,
		Stderr: os.Stderr,
	}
	os.Exit(cli.Run(os.Args[1:]))
}
