package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var eventIDPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func runRerun(config clientConfig, args []string) error {
	if err := config.validate(); err != nil {
		return err
	}
	flags := flag.NewFlagSet("rerun", flag.ContinueOnError)
	assumeYes := flags.Bool("yes", false, "execute without confirmation")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 1 || !eventIDPattern.MatchString(flags.Arg(0)) {
		return fmt.Errorf("usage: athena rerun [--yes] EVENT_ID")
	}
	eventID := flags.Arg(0)
	request, err := config.request(http.MethodGet, "/api/commands/"+eventID+"/command", nil)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 15 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if err := requireSuccess(response); err != nil {
		return err
	}
	contents, err := io.ReadAll(io.LimitReader(response.Body, 1048577))
	if err != nil {
		return err
	}
	if len(contents) > 1048576 {
		return fmt.Errorf("command is too large to rerun")
	}
	commandText := string(contents)
	fmt.Printf("Re-running %s: %s\n", eventID, commandText)
	if !*assumeYes {
		info, err := os.Stdin.Stat()
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeCharDevice == 0 {
			return fmt.Errorf("confirmation required; use --yes to execute without a prompt")
		}
		fmt.Print("Execute this command? [y/N] ")
		answer, err := bufio.NewReader(os.Stdin).ReadString('\n')
		if err != nil && err != io.EOF {
			return err
		}
		switch strings.ToLower(strings.TrimSpace(answer)) {
		case "y", "yes":
		default:
			return fmt.Errorf("cancelled")
		}
	}

	shellName := os.Getenv("ATHENA_CLIENT_SHELL")
	if shellName == "" {
		shellName = os.Getenv("ATHENA_SHELL")
	}
	if shellName == "" {
		shellName = filepath.Base(os.Getenv("SHELL"))
	}
	if shellName != "bash" && shellName != "zsh" {
		return fmt.Errorf("rerun supports bash or zsh")
	}
	command := exec.Command(shellName, "-c", commandText)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	return command.Run()
}
