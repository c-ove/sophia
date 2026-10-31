package main

import (
	"crypto/rand"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

var runtimeAssetFiles = []string{
	"athena-shell.sh",
	"bashrc",
	"zdotdir/.zshrc",
	"zdotdir/.zshenv",
	"zdotdir/.zprofile",
	"zdotdir/.zlogin",
}

func runShell(config clientConfig, args []string) error {
	if err := config.validate(); err != nil {
		return err
	}
	defaultShell := os.Getenv("ATHENA_SHELL")
	if defaultShell == "" {
		defaultShell = filepath.Base(os.Getenv("SHELL"))
	}
	flags := flag.NewFlagSet("shell", flag.ContinueOnError)
	shellName := flags.String("shell", defaultShell, "shell to capture: bash or zsh")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("shell accepts no positional arguments")
	}
	if *shellName != "bash" && *shellName != "zsh" {
		return fmt.Errorf("supported shells are bash and zsh")
	}
	if _, err := exec.LookPath("script"); err != nil {
		return fmt.Errorf("required terminal recorder not found: script")
	}
	if err := os.MkdirAll(config.spoolDir, 0700); err != nil {
		return err
	}

	sessionID, err := newUUID()
	if err != nil {
		return err
	}
	sessionDir := filepath.Join(config.spoolDir, sessionID)
	runtimeDir := filepath.Join(config.baseDir, "runtime", sessionID)
	if err := os.MkdirAll(sessionDir, 0700); err != nil {
		return err
	}
	if err := os.MkdirAll(runtimeDir, 0700); err != nil {
		return err
	}
	defer os.RemoveAll(runtimeDir)
	if err := writeRuntimeAssets(runtimeDir); err != nil {
		return err
	}

	rawLog := filepath.Join(sessionDir, "terminal.raw")
	if err := os.WriteFile(rawLog, nil, 0600); err != nil {
		return err
	}
	defer os.Remove(rawLog)
	hostIP := os.Getenv("ATHENA_HOST_IP")
	if hostIP == "" {
		hostIP, err = detectHostIP()
		if err != nil {
			return fmt.Errorf("could not determine host IP; set ATHENA_HOST_IP: %w", err)
		}
	}
	hostname, _ := os.Hostname()
	hostname = safeHostname(hostname)
	if hostname == "" {
		hostname = "unknown"
	}
	home, _ := os.UserHomeDir()
	originalZdotdir := os.Getenv("ZDOTDIR")
	if originalZdotdir == "" {
		originalZdotdir = home
	}
	environment := append(config.environment(),
		"ATHENA_SESSION_ID="+sessionID,
		"ATHENA_SESSION_DIR="+sessionDir,
		"ATHENA_RAW_LOG="+rawLog,
		"ATHENA_HOST_IP="+hostIP,
		"ATHENA_HOSTNAME="+hostname,
		"ATHENA_CLIENT_SHELL="+*shellName,
		"ATHENA_BASHRC="+filepath.Join(runtimeDir, "bashrc"),
		"ATHENA_ORIGINAL_ZDOTDIR="+originalZdotdir,
		"ATHENA_MAX_OUTPUT_BYTES="+environmentValue(os.Environ(), "ATHENA_MAX_OUTPUT_BYTES", "65536"),
		"ATHENA_MAX_SPOOL_FILES="+environmentValue(os.Environ(), "ATHENA_MAX_SPOOL_FILES", "1000"),
	)
	if *shellName == "zsh" {
		environment = append(environment, "ZDOTDIR="+filepath.Join(runtimeDir, "zdotdir"))
	}
	if err := startForwarder(config, environment); err != nil {
		return err
	}

	var command *exec.Cmd
	if runtime.GOOS == "linux" {
		shellCommand := *shellName + " -i"
		if *shellName == "bash" {
			shellCommand = `bash --rcfile "$ATHENA_BASHRC" -i`
		}
		command = exec.Command("script", "--quiet", "--flush", "--log-out", rawLog, "--command", shellCommand)
	} else {
		arguments := []string{"-q", rawLog, *shellName}
		if *shellName == "bash" {
			arguments = append(arguments, "--rcfile", filepath.Join(runtimeDir, "bashrc"))
		}
		arguments = append(arguments, "-i")
		command = exec.Command("script", arguments...)
	}
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	command.Env = environment
	return command.Run()
}

func writeRuntimeAssets(runtimeDir string) error {
	for _, name := range runtimeAssetFiles {
		contents, err := clientAssets.ReadFile(name)
		if err != nil {
			return err
		}
		destination := filepath.Join(runtimeDir, name)
		if err := os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
			return err
		}
		if err := os.WriteFile(destination, contents, 0600); err != nil {
			return err
		}
	}
	return nil
}

func startForwarder(config clientConfig, environment []string) error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(config.baseDir, 0700); err != nil {
		return err
	}
	logFile, err := os.OpenFile(filepath.Join(config.baseDir, "forwarder.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer logFile.Close()
	command := exec.Command(executable, "forwarder")
	command.Env = environment
	command.Stdout = logFile
	command.Stderr = logFile
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		return err
	}
	return command.Process.Release()
}

func newUUID() (string, error) {
	bytes := make([]byte, 16)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", bytes[0:4], bytes[4:6], bytes[6:8], bytes[8:10], bytes[10:16]), nil
}

func detectHostIP() (string, error) {
	connection, err := net.Dial("udp", "1.1.1.1:80")
	if err == nil {
		defer connection.Close()
		address, ok := connection.LocalAddr().(*net.UDPAddr)
		if ok && address.IP.To4() != nil {
			return address.IP.String(), nil
		}
	}
	interfaces, err := net.Interfaces()
	if err != nil {
		return "", err
	}
	for _, networkInterface := range interfaces {
		if networkInterface.Flags&net.FlagUp == 0 || networkInterface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, _ := networkInterface.Addrs()
		for _, address := range addresses {
			network, ok := address.(*net.IPNet)
			if ok && network.IP.To4() != nil {
				return network.IP.String(), nil
			}
		}
	}
	return "", fmt.Errorf("no non-loopback IPv4 address found")
}

func safeHostname(value string) string {
	return strings.Map(func(character rune) rune {
		if character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' ||
			character >= '0' && character <= '9' || character == '.' || character == '_' || character == '-' {
			return character
		}
		return -1
	}, value)
}
