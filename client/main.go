package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	if len(args) == 0 {
		printUsage()
		return 2
	}
	if args[0] == "help" || args[0] == "--help" || args[0] == "-h" {
		printUsage()
		return 0
	}

	config := loadConfig()
	var err error
	switch args[0] {
	case "shell":
		err = runShell(config, args[1:])
	case "forwarder":
		err = runForwarder(config, args[1:])
	case "history":
		err = runHistory(config, args[1:])
	case "rerun":
		err = runRerun(config, args[1:])
	default:
		printUsage()
		return 2
	}
	if err == nil {
		return 0
	}
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		return exitError.ExitCode()
	}
	fmt.Fprintln(os.Stderr, "sophia:", err)
	return 1
}

func printUsage() {
	fmt.Println(`Sophia command client

Usage:
  sophia shell [--shell bash|zsh]  Start a captured interactive shell
  sophia forwarder                 Deliver queued command events
  sophia history                   Print all commands on the server
  sophia rerun [--yes] EVENT_ID    Re-run a command by event ID

Configuration:
  SOPHIA_SERVER_URL  Server URL, for example http://10.1.10.4:8000
  SOPHIA_TOKEN       Server ingestion token`)
}
