package pwned

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const userAgent = "pwned-check (+https://github.com/phillipmcmahon/pwned-check)"

type RangeProvider struct {
	BaseURL string
	Client  *http.Client
	Header  http.Header
	Timeout time.Duration
}

func NewHIBPProvider(endpoint string, timeout time.Duration) RangeProvider {
	headers := http.Header{}
	headers.Set("User-Agent", userAgent)
	headers.Set("Add-Padding", "true")
	return RangeProvider{
		BaseURL: strings.TrimRight(endpoint, "/") + "/",
		Client:  &http.Client{Timeout: timeout},
		Header:  headers,
		Timeout: timeout,
	}
}

func NewLocalProvider(baseURL string, timeout time.Duration) RangeProvider {
	return RangeProvider{
		BaseURL: strings.TrimRight(baseURL, "/") + "/range/",
		Client:  &http.Client{Timeout: timeout},
		Header:  http.Header{},
		Timeout: timeout,
	}
}

func (p RangeProvider) Lookup(prefix, suffix string) (int, error) {
	if p.Timeout <= 0 {
		return 0, fmt.Errorf("provider timeout must be positive")
	}

	ctx := context.Background()
	ctx, cancel := context.WithTimeout(ctx, p.Timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.BaseURL+prefix, nil)
	if err != nil {
		return 0, err
	}
	for key, values := range p.Header {
		for _, value := range values {
			req.Header.Add(key, value)
		}
	}

	client := p.Client
	if client == nil {
		client = &http.Client{}
	}
	resp, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return 0, fmt.Errorf("provider returned HTTP %d", resp.StatusCode)
	}
	return ParseRangeResponse(resp.Body, suffix)
}

func ParseRangeResponse(reader io.Reader, suffix string) (int, error) {
	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}
		if !strings.EqualFold(parts[0], suffix) {
			continue
		}
		count, err := strconv.Atoi(strings.TrimSpace(parts[1]))
		if err != nil || count < 0 {
			return 0, nil
		}
		return count, nil
	}
	if err := scanner.Err(); err != nil {
		return 0, err
	}
	return 0, nil
}
