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

const userAgent = "pwned-check/0.2 (+https://github.com/phillipmcmahon/pwned-check)"

type RangeProvider struct {
	BaseURL string
	Client  *http.Client
	Header  http.Header
}

func NewHIBPProvider(endpoint string, timeout time.Duration) RangeProvider {
	headers := http.Header{}
	headers.Set("User-Agent", userAgent)
	headers.Set("Add-Padding", "true")
	return RangeProvider{
		BaseURL: strings.TrimRight(endpoint, "/") + "/",
		Client:  &http.Client{Timeout: timeout},
		Header:  headers,
	}
}

func NewLocalProvider(baseURL string, timeout time.Duration) RangeProvider {
	return RangeProvider{
		BaseURL: strings.TrimRight(baseURL, "/") + "/range/",
		Client:  &http.Client{Timeout: timeout},
		Header:  http.Header{},
	}
}

func (p RangeProvider) Lookup(prefix, suffix string) (int, error) {
	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, p.BaseURL+prefix, nil)
	if err != nil {
		return 0, err
	}
	for key, values := range p.Header {
		for _, value := range values {
			req.Header.Add(key, value)
		}
	}

	resp, err := p.Client.Do(req)
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
		if err != nil {
			return 0, nil
		}
		return count, nil
	}
	if err := scanner.Err(); err != nil {
		return 0, err
	}
	return 0, nil
}
