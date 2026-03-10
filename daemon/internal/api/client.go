package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"time"
)

type Client struct {
	httpClient *http.Client
}

func New(socketPath string) *Client {
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var dialer net.Dialer
			return dialer.DialContext(ctx, "unix", socketPath)
		},
	}

	return &Client{
		httpClient: &http.Client{
			Timeout:   10 * time.Second,
			Transport: transport,
		},
	}
}

func (c *Client) Do(ctx context.Context, method, path string, payload any, target any) error {
	var body io.Reader
	if payload != nil {
		data, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		body = bytes.NewReader(data)
	}

	request, err := http.NewRequestWithContext(ctx, method, "http://nest"+path, body)
	if err != nil {
		return err
	}
	if payload != nil {
		request.Header.Set("Content-Type", "application/json")
	}

	response, err := c.httpClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()

	if response.StatusCode >= 400 {
		var apiErr map[string]string
		if decodeErr := json.NewDecoder(response.Body).Decode(&apiErr); decodeErr == nil {
			return &Error{Message: apiErr["error"], StatusCode: response.StatusCode}
		}
		return &Error{Message: response.Status, StatusCode: response.StatusCode}
	}

	if target == nil {
		return nil
	}
	return json.NewDecoder(response.Body).Decode(target)
}

type Error struct {
	Message    string
	StatusCode int
}

func (e *Error) Error() string {
	return e.Message
}
