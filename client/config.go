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
	baseDir := os.Getenv("ATHENA_BASE_DIR")
	if baseDir == "" {
		baseDir = filepath.Join(home, ".cache", "athena")
	}
	spoolDir := os.Getenv("ATHENA_SPOOL_DIR")
	if spoolDir == "" {
		spoolDir = filepath.Join(baseDir, "spool")
	}
	return clientConfig{
		serverURL: strings.TrimRight(os.Getenv("ATHENA_SERVER_URL"), "/"),
		token:     os.Getenv("ATHENA_TOKEN"),
		baseDir:   baseDir,
		spoolDir:  spoolDir,
	}
}

func (config clientConfig) validate() error {
	if config.serverURL == "" {
		return fmt.Errorf("ATHENA_SERVER_URL is required")
	}
	if config.token == "" {
		return fmt.Errorf("ATHENA_TOKEN is required")
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
		"ATHENA_SERVER_URL="+config.serverURL,
		"ATHENA_TOKEN="+config.token,
		"ATHENA_BASE_DIR="+config.baseDir,
		"ATHENA_SPOOL_DIR="+config.spoolDir,
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
