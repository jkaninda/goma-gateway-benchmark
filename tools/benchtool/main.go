// benchtool is the measurement side of the Goma Gateway benchmark harness.
//
// Subcommands:
//
//	backend   a test origin server (the thing gateways proxy to)
//	probe     route-propagation prober: time from "route written" to "first 200"
//	churn     continuous prober used while a route is rewritten underneath it
//	failover  steady load across N paths while one backend is taken away
//	sample    CPU/RSS sampler for a process tree, straight out of /proc
//
// It has no dependencies outside the standard library on purpose: the harness
// has to build on a machine that can reach nothing but the Go toolchain.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: benchtool <backend|probe|churn|failover|sample> [flags]")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "backend":
		runBackend(os.Args[2:])
	case "probe":
		runProbe(os.Args[2:])
	case "churn":
		runChurn(os.Args[2:])
	case "failover":
		runFailover(os.Args[2:])
	case "sample":
		runSample(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand %q\n", os.Args[1])
		os.Exit(2)
	}
}

// ---------------------------------------------------------------- backend --

func runBackend(args []string) {
	fs := flag.NewFlagSet("backend", flag.ExitOnError)
	addr := fs.String("addr", ":8080", "listen address")
	id := fs.String("id", "b1", "backend identity, echoed in the X-Backend-Id header and body")
	payload := fs.Int("payload", 100, "response body size in bytes")
	_ = fs.Parse(args)

	body := []byte(strings.Repeat("x", *payload))
	var hits atomic.Int64
	var accepts atomic.Int64

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.Header().Set("X-Backend-Id", *id)
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(body)
	})
	// Counter endpoint: lets a test assert how many requests actually reached
	// this origin, which is the number the failover scenario cares about.
	mux.HandleFunc("/_bench/hits", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("reset") == "1" {
			fmt.Fprintf(w, "%d\n", hits.Swap(0))
			return
		}
		fmt.Fprintf(w, "%d\n", hits.Load())
	})
	// Requests and accepted connections together answer one question no latency
	// number can: does the gateway reuse upstream connections, or open a new one
	// per request? A ratio near 1 request per connection means no pooling.
	mux.HandleFunc("/_bench/stats", func(w http.ResponseWriter, r *http.Request) {
		h, a := hits.Load(), accepts.Load()
		if r.URL.Query().Get("reset") == "1" {
			h, a = hits.Swap(0), accepts.Swap(0)
		}
		fmt.Fprintf(w, "requests=%d connections=%d\n", h, a)
	})

	srv := &http.Server{
		Addr:         *addr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  120 * time.Second,
	}
	base, err := net.Listen("tcp", *addr)
	if err != nil {
		fatal("backend listen: %v", err)
	}
	ln := &countingListener{Listener: base, accepts: &accepts}
	fmt.Fprintf(os.Stderr, "backend %s listening on %s (payload %d bytes)\n", *id, *addr, *payload)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-stop
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	}()
	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		fatal("backend serve: %v", err)
	}
}

// countingListener counts accepted TCP connections.
type countingListener struct {
	net.Listener
	accepts *atomic.Int64
}

func (l *countingListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err == nil {
		l.accepts.Add(1)
	}
	return c, err
}

// ------------------------------------------------------------------ probe --

// probeResult is one row of the propagation CSV.
type probeResult struct {
	Index      int
	WriteToOK  time.Duration
	Attempts   int
	ErrorCodes map[int]int // non-404 failures seen while waiting
}

// runProbe reads a newline-delimited stream of "<index> <unix_nanos> <url>"
// records on stdin. Each record says: a route was written at that instant,
// probe this URL until it answers 200. It writes one CSV row per route.
//
// Splitting it this way keeps the *writing* of route files in the shell
// (where each gateway's config format lives) and the *timing* in Go.
func runProbe(args []string) {
	fs := flag.NewFlagSet("probe", flag.ExitOnError)
	out := fs.String("out", "", "CSV output path (default stdout)")
	timeout := fs.Duration("timeout", 30*time.Second, "give up on a route after this long")
	interval := fs.Duration("interval", 2*time.Millisecond, "polling interval")
	_ = fs.Parse(args)

	w, closeOut := openOut(*out)
	defer closeOut()

	client := newClient(1, 2*time.Second)
	fmt.Fprintln(w, "index,propagation_ms,attempts,error_codes")

	dec := json.NewDecoder(os.Stdin)
	for {
		var rec struct {
			Index int    `json:"index"`
			At    int64  `json:"at"`
			URL   string `json:"url"`
		}
		if err := dec.Decode(&rec); err == io.EOF {
			break
		} else if err != nil {
			fatal("probe: decode stdin: %v", err)
		}

		start := time.Unix(0, rec.At)
		res := probeVersionOne(client, rec.URL, start, *timeout, *interval)
		res.Index = rec.Index

		// A route that never propagated is written as exactly -1, not as a
		// formatted negative duration: -1 ns renders as "-0.0", which every
		// downstream `value >= 0` check reads as the fastest possible result.
		ms := "-1"
		if res.WriteToOK >= 0 {
			ms = fmt.Sprintf("%.1f", float64(res.WriteToOK)/float64(time.Millisecond))
		}
		fmt.Fprintf(w, "%d,%s,%d,%s\n", res.Index, ms, res.Attempts, codesString(res.ErrorCodes))
		if f, ok := w.(*os.File); ok {
			_ = f.Sync()
		}
	}
}

func probeVersionOne(client *http.Client, url string, start time.Time, timeout, interval time.Duration) probeResult {
	res := probeResult{WriteToOK: -1, ErrorCodes: map[int]int{}}
	deadline := start.Add(timeout)
	for time.Now().Before(deadline) {
		res.Attempts++
		code, err := get(client, url)
		if err == nil && code == http.StatusOK {
			res.WriteToOK = time.Since(start)
			return res
		}
		// 404 is the expected "not there yet" answer. Anything else (503, 500,
		// connection refused) is a defect: the gateway accepted a request for a
		// route it could not yet serve. This is the metric that separated Envoy
		// Gateway from the rest in the upstream benchmark.
		switch {
		case err != nil:
			res.ErrorCodes[0]++
		case code != http.StatusNotFound:
			res.ErrorCodes[code]++
		}
		time.Sleep(interval)
	}
	return res
}

// ------------------------------------------------------------------ churn --

// runChurn hammers a single URL for a fixed duration and reports the response
// code distribution. The harness rewrites the route underneath it while this
// runs; every non-2xx is an error the gateway introduced by reloading.
func runChurn(args []string) {
	fs := flag.NewFlagSet("churn", flag.ExitOnError)
	url := fs.String("url", "", "URL to probe")
	dur := fs.Duration("duration", 10*time.Second, "how long to probe")
	conns := fs.Int("connections", 4, "concurrent probers")
	out := fs.String("out", "", "CSV output path (default stdout)")
	timeline := fs.String("timeline", "", "optional per-bucket CSV timeline path")
	bucket := fs.Duration("bucket", 100*time.Millisecond, "timeline bucket width")
	_ = fs.Parse(args)
	if *url == "" {
		fatal("churn: -url is required")
	}

	w, closeOut := openOut(*out)
	defer closeOut()

	var mu sync.Mutex
	codes := map[int]int{}
	// Which origin answered. The harness flips the route between two origins
	// during this test; without this column a run where no reload actually
	// happened would look identical to a flawless one.
	served := map[string]int{}
	// Per-bucket origin counts. Counting how many times the majority origin
	// changes over time is the only reliable way to tell "applied every change"
	// from "coalesced them all into one reload": a gateway that applies one late
	// change still ends up hitting both origins, so the totals alone cannot
	// distinguish the two.
	buckets := map[int]map[string]int{}
	var total, errs atomic.Int64

	start := time.Now()
	deadline := start.Add(*dur)
	var wg sync.WaitGroup
	for i := 0; i < *conns; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			client := newClient(1, 2*time.Second)
			for time.Now().Before(deadline) {
				code, id, err := getWithBackend(client, *url)
				total.Add(1)
				key := code
				if err != nil {
					key = 0
					errs.Add(1)
				} else if code < 200 || code > 299 {
					errs.Add(1)
				}
				b := int(time.Since(start) / *bucket)
				mu.Lock()
				codes[key]++
				if id != "" {
					served[id]++
					if buckets[b] == nil {
						buckets[b] = map[string]int{}
					}
					buckets[b][id]++
				}
				mu.Unlock()
			}
		}()
	}
	wg.Wait()

	flips := countFlips(buckets)
	fmt.Fprintln(w, "requests,errors,error_pct,codes,served_by,observed_flips")
	pct := 0.0
	if total.Load() > 0 {
		pct = 100 * float64(errs.Load()) / float64(total.Load())
	}
	fmt.Fprintf(w, "%d,%d,%.2f,%s,%s,%d\n",
		total.Load(), errs.Load(), pct, codesString(codes), stringsMap(served), flips)

	if *timeline != "" {
		writeChurnTimeline(*timeline, buckets, *bucket)
	}
}

// countFlips returns how many times the dominant origin changes from one
// bucket to the next — i.e. how many configuration changes actually reached
// the data plane during the probe window.
func countFlips(buckets map[int]map[string]int) int {
	keys := make([]int, 0, len(buckets))
	for k := range buckets {
		keys = append(keys, k)
	}
	sort.Ints(keys)
	flips, prev := 0, ""
	for _, k := range keys {
		top, best := "", 0
		for id, n := range buckets[k] {
			if n > best || (n == best && id < top) {
				top, best = id, n
			}
		}
		if top == "" {
			continue
		}
		if prev != "" && top != prev {
			flips++
		}
		prev = top
	}
	return flips
}

func writeChurnTimeline(path string, buckets map[int]map[string]int, width time.Duration) {
	f, err := os.Create(path)
	if err != nil {
		return
	}
	defer f.Close()
	ids := map[string]bool{}
	keys := make([]int, 0, len(buckets))
	for k, m := range buckets {
		keys = append(keys, k)
		for id := range m {
			ids[id] = true
		}
	}
	sort.Ints(keys)
	cols := make([]string, 0, len(ids))
	for id := range ids {
		cols = append(cols, id)
	}
	sort.Strings(cols)
	fmt.Fprintf(f, "ms,%s\n", strings.Join(cols, ","))
	for _, k := range keys {
		fmt.Fprintf(f, "%d", int(time.Duration(k)*width/time.Millisecond))
		for _, id := range cols {
			fmt.Fprintf(f, ",%d", buckets[k][id])
		}
		fmt.Fprintln(f)
	}
}

// --------------------------------------------------------------- failover --

// runFailover drives steady, rate-limited load across N paths that all resolve
// to the same pool of backends, and reports the response codes plus which
// backend served each request. The harness blackholes one backend in the
// middle; what matters is how many requests the gateway keeps sending to it.
func runFailover(args []string) {
	fs := flag.NewFlagSet("failover", flag.ExitOnError)
	base := fs.String("base", "http://127.0.0.1:8080", "gateway base URL")
	prefix := fs.String("prefix", "/fo", "path prefix; paths are <prefix>-<i>/")
	paths := fs.Int("paths", 16, "number of distinct paths to rotate over")
	rps := fs.Int("rps", 200, "target requests per second (total)")
	dur := fs.Duration("duration", 90*time.Second, "test duration")
	conns := fs.Int("connections", 16, "concurrent workers")
	out := fs.String("out", "", "CSV output path (default stdout)")
	timeline := fs.String("timeline", "", "optional per-second CSV timeline path")
	_ = fs.Parse(args)

	w, closeOut := openOut(*out)
	defer closeOut()

	type bucket struct {
		ok, fail int
		byID     map[string]int
	}
	var mu sync.Mutex
	codes := map[int]int{}
	served := map[string]int{}
	seconds := map[int]*bucket{}

	start := time.Now()
	deadline := start.Add(*dur)
	ticker := time.NewTicker(time.Second / time.Duration(*rps))
	defer ticker.Stop()

	work := make(chan int, *conns*4)
	var wg sync.WaitGroup
	for i := 0; i < *conns; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			client := newClient(2, 3*time.Second)
			for n := range work {
				url := fmt.Sprintf("%s%s-%d/", *base, *prefix, n%*paths)
				code, id, err := getWithBackend(client, url)
				sec := int(time.Since(start).Seconds())
				mu.Lock()
				b := seconds[sec]
				if b == nil {
					b = &bucket{byID: map[string]int{}}
					seconds[sec] = b
				}
				switch {
				case err != nil:
					codes[0]++
					b.fail++
				case code >= 200 && code <= 299:
					codes[code]++
					b.ok++
					if id != "" {
						served[id]++
						b.byID[id]++
					}
				default:
					codes[code]++
					b.fail++
					if id != "" {
						served[id]++
						b.byID[id]++
					}
				}
				mu.Unlock()
			}
		}()
	}

	n := 0
	for time.Now().Before(deadline) {
		<-ticker.C
		work <- n
		n++
	}
	close(work)
	wg.Wait()

	total, failed := 0, 0
	for code, c := range codes {
		total += c
		if code == 0 || code < 200 || code > 299 {
			failed += c
		}
	}
	fmt.Fprintln(w, "requests,failed,failed_pct,codes,served_by")
	pct := 0.0
	if total > 0 {
		pct = 100 * float64(failed) / float64(total)
	}
	fmt.Fprintf(w, "%d,%d,%.2f,%s,%s\n", total, failed, pct, codesString(codes), stringsMap(served))

	if *timeline != "" {
		tf, err := os.Create(*timeline)
		if err == nil {
			defer tf.Close()
			fmt.Fprintln(tf, "second,ok,failed")
			keys := make([]int, 0, len(seconds))
			for k := range seconds {
				keys = append(keys, k)
			}
			sort.Ints(keys)
			for _, k := range keys {
				fmt.Fprintf(tf, "%d,%d,%d\n", k, seconds[k].ok, seconds[k].fail)
			}
		}
	}
}

// ------------------------------------------------------------------ utils --

func newClient(maxConns int, timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			MaxIdleConns:        maxConns,
			MaxIdleConnsPerHost: maxConns,
			MaxConnsPerHost:     maxConns,
			IdleConnTimeout:     30 * time.Second,
			DisableCompression:  true,
			DialContext: (&net.Dialer{
				Timeout:   2 * time.Second,
				KeepAlive: 30 * time.Second,
			}).DialContext,
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

func get(client *http.Client, url string) (int, error) {
	resp, err := client.Get(url)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode, nil
}

func getWithBackend(client *http.Client, url string) (int, string, error) {
	resp, err := client.Get(url)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode, resp.Header.Get("X-Backend-Id"), nil
}

func openOut(path string) (io.Writer, func()) {
	if path == "" {
		return os.Stdout, func() {}
	}
	f, err := os.Create(path)
	if err != nil {
		fatal("open %s: %v", path, err)
	}
	return f, func() { _ = f.Close() }
}

// codesString renders a code histogram as "503:12 500:3"; code 0 means the
// request never got an HTTP response (connection refused, reset, timeout).
func codesString(codes map[int]int) string {
	if len(codes) == 0 {
		return ""
	}
	keys := make([]int, 0, len(codes))
	for k := range codes {
		keys = append(keys, k)
	}
	sort.Ints(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		label := fmt.Sprint(k)
		if k == 0 {
			label = "conn_error"
		}
		parts = append(parts, fmt.Sprintf("%s:%d", label, codes[k]))
	}
	return strings.Join(parts, " ")
}

func stringsMap(m map[string]int) string {
	if len(m) == 0 {
		return ""
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s:%d", k, m[k]))
	}
	return strings.Join(parts, " ")
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
