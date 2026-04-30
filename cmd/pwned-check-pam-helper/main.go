package main

import (
	"os"

	"github.com/phillipmcmahon/pwned-check/internal/pamhelper"
)

func main() {
	helper := pamhelper.Helper{
		Stdin:  os.Stdin,
		Stdout: os.Stdout,
		Stderr: os.Stderr,
	}
	os.Exit(helper.Run(os.Args[1:]))
}
