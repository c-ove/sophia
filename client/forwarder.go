package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"syscall"
	"time"
)

func runForwarder(config clientConfig, args []string) error {
	if len(args) != 0 {
		return fmt.Errorf("forwarder accepts no arguments")
	}
	if err := config.validate(); err != nil {
		return err
	}
	if err := os.MkdirAll(config.spoolDir, 0700); err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(config.spoolDir, ".forwarder.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if err == syscall.EWOULDBLOCK {
			return nil
		}
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)

	retrySeconds := 5
	if value, err := strconv.Atoi(os.Getenv("ATHENA_RETRY_SECONDS")); err == nil && value > 0 {
		retrySeconds = value
	}
	for {
		if err := sendNextBatch(config); err != nil {
			fmt.Fprintln(os.Stderr, "forwarder:", err)
			time.Sleep(time.Duration(retrySeconds) * time.Second)
			continue
		}
		time.Sleep(time.Second)
	}
}

func sendNextBatch(config clientConfig) error {
	files, err := filepath.Glob(filepath.Join(config.spoolDir, "*", "*.json"))
	if err != nil {
		return err
	}
	if len(files) == 0 {
		return nil
	}
	sort.Strings(files)

	var payload bytes.Buffer
	payload.WriteString(`{"events":[`)
	selected := make([]string, 0, 20)
	totalBytes := 32
	for _, path := range files {
		contents, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if !json.Valid(contents) {
			return fmt.Errorf("invalid queued event: %s", path)
		}
		if len(selected) > 0 && (len(selected) >= 20 || totalBytes+len(contents) > 3000000) {
			break
		}
		if len(selected) > 0 {
			payload.WriteByte(',')
		}
		payload.Write(contents)
		totalBytes += len(contents) + 1
		selected = append(selected, path)
	}
	payload.WriteString("]}\n")

	request, err := config.request(http.MethodPost, "/api/events", &payload)
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 20 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if err := requireSuccess(response); err != nil {
		return err
	}
	if _, err := io.Copy(io.Discard, response.Body); err != nil {
		return err
	}
	for _, path := range selected {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}
