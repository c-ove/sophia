package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

type clientConfig struct {
	serverURL string
	token     string
	baseDir   string
	spoolDir  string
}

func loadConfig() clientConfig {
	home, _ := os.UserHomeDir()
	baseDir := os.Getenv("SOPHIA_BASE_DIR")
	if baseDir == "" {
		baseDir = filepath.Join(home, ".cache", "sophia")
	}
	spoolDir := os.Getenv("SOPHIA_SPOOL_DIR")
	if spoolDir == "" {
		spoolDir = filepath.Join(baseDir, "spool")
	}
	return clientConfig{
		serverURL: strings.TrimRight(os.Getenv("SOPHIA_SERVER_URL"), "/"),
		token:     os.Getenv("SOPHIA_TOKEN"),
		baseDir:   baseDir,
		spoolDir:  spoolDir,
	}
}

func (config clientConfig) validate() error {
	if config.serverURL == "" {
		return fmt.Errorf("SOPHIA_SERVER_URL is required")
	}
	if config.token == "" {
		return fmt.Errorf("SOPHIA_TOKEN is required")
	}
	return nil
}

func (config clientConfig) request(method, path string, body io.Reader) (*http.Request, error) {
	request, err := http.NewRequest(method, config.serverURL+path, body)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+config.token)
	return request, nil
}

func (config clientConfig) environment() []string {
	return append(os.Environ(),
		"SOPHIA_SERVER_URL="+config.serverURL,
		"SOPHIA_TOKEN="+config.token,
		"SOPHIA_BASE_DIR="+config.baseDir,
		"SOPHIA_SPOOL_DIR="+config.spoolDir,
	)
}

func environmentValue(environment []string, key, fallback string) string {
	prefix := key + "="
	for index := len(environment) - 1; index >= 0; index-- {
		if strings.HasPrefix(environment[index], prefix) {
			return strings.TrimPrefix(environment[index], prefix)
		}
	}
	return fallback
}
