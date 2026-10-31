package main

import (
	"fmt"
	"io"
	"net/http"
	"strings"
)

func requireSuccess(response *http.Response) error {
	if response.StatusCode >= 200 && response.StatusCode < 300 {
		return nil
	}
	body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
	message := strings.TrimSpace(string(body))
	if message == "" {
		return fmt.Errorf("server returned %s", response.Status)
	}
	return fmt.Errorf("server returned %s: %s", response.Status, message)
}
