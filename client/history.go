package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

func runHistory(config clientConfig, args []string) error {
	if len(args) != 0 {
		return fmt.Errorf("history accepts no arguments")
	}
	if err := config.validate(); err != nil {
		return err
	}
	request, err := config.request(http.MethodGet, "/api/commands/export", nil)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 60 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if err := requireSuccess(response); err != nil {
		return err
	}
	_, err = io.Copy(os.Stdout, response.Body)
	return err
}
