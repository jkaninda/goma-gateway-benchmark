package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// runSample samples a process tree's CPU and RSS from /proc until it is killed
// or the root process exits. CPU is reported in cores (1.00 = one core busy).
//
// It follows the whole tree rather than the root pid alone: nginx and haproxy
// run workers as separate processes, and nginx in particular keeps old workers
// alive for a while after a reload — exactly the cost the route-scale scenario
// is trying to see.
func runSample(args []string) {
	fs := flag.NewFlagSet("sample", flag.ExitOnError)
	pid := fs.Int("pid", 0, "root pid of the process tree to sample")
	interval := fs.Duration("interval", 500*time.Millisecond, "sampling interval")
	out := fs.String("out", "", "CSV output path (default stdout)")
	_ = fs.Parse(args)
	if *pid == 0 {
		fatal("sample: -pid is required")
	}

	w, closeOut := openOut(*out)
	defer closeOut()
	fmt.Fprintln(w, "unix_ms,cpu_cores,rss_mb,threads,procs")

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	hz := float64(100) // CLK_TCK is 100 on every Linux target this harness runs on.
	var prevTicks float64
	var prevAt time.Time

	// CPU has to be accumulated per pid and remembered after a pid is gone.
	// nginx and haproxy replace their workers on every reload, so a naive
	// "sum the tree now" reading drops the CPU of every worker that exited
	// between two samples — it even goes negative — and would report reload
	// cost as near zero, which is the opposite of the truth.
	acc := &cpuAccumulator{last: map[int]float64{}}

	tick := time.NewTicker(*interval)
	defer tick.Stop()
	for {
		select {
		case <-stop:
			return
		case now := <-tick.C:
			ticks, rssKB, threads, procs, alive := sampleTree(*pid, acc)
			if !alive {
				return
			}
			if !prevAt.IsZero() {
				dt := now.Sub(prevAt).Seconds()
				if dt > 0 {
					cpu := ((ticks - prevTicks) / hz) / dt
					fmt.Fprintf(w, "%d,%.4f,%.2f,%d,%d\n",
						now.UnixMilli(), cpu, float64(rssKB)/1024, threads, procs)
					if f, ok := w.(*os.File); ok {
						_ = f.Sync()
					}
				}
			}
			prevTicks, prevAt = ticks, now
		}
	}
}

// cpuAccumulator turns per-pid CPU counters into one monotonically increasing
// total for a process tree whose members come and go.
type cpuAccumulator struct {
	last    map[int]float64 // last reading per live pid
	retired float64         // sum of the final readings of pids that have gone
}

// total records this sample's live pids and returns the tree's cumulative CPU,
// including every pid that has since exited.
//
// Readings are kept for pids that are no longer there rather than dropped when
// they first go missing: collectTree can miss a pid that is exiting exactly as
// the tree is walked, and a pid that came back would then be counted twice.
// Holding the last value is both correct and idempotent.
func (a *cpuAccumulator) total(live map[int]float64) float64 {
	for pid, v := range live {
		// A pid can be reused after its predecessor exits; the counter then
		// restarts from a lower value. Bank the old process's final reading so
		// the total never goes backwards.
		if prev, ok := a.last[pid]; ok && v < prev {
			a.retired += prev
		}
		a.last[pid] = v
	}
	sum := a.retired
	for _, v := range a.last {
		sum += v
	}
	return sum
}

func sampleTree(root int, acc *cpuAccumulator) (ticks float64, rssKB, threads, procs int, alive bool) {
	pids := collectTree(root)
	if len(pids) == 0 {
		return 0, 0, 0, 0, false
	}
	live := make(map[int]float64, len(pids))
	for _, pid := range pids {
		u, s, n, ok := readStat(pid)
		if !ok {
			continue
		}
		live[pid] = u + s
		threads += n
		procs++
		rssKB += readRSS(pid)
	}
	if procs == 0 {
		return 0, 0, 0, 0, false
	}
	return acc.total(live), rssKB, threads, procs, true
}

func collectTree(root int) []int {
	out := []int{}
	seen := map[int]bool{}
	var walk func(int)
	walk = func(pid int) {
		if seen[pid] {
			return
		}
		if _, err := os.Stat(filepath.Join("/proc", strconv.Itoa(pid))); err != nil {
			return
		}
		seen[pid] = true
		out = append(out, pid)
		// /proc/<pid>/task/<tid>/children lists direct children per thread.
		tasks, err := os.ReadDir(filepath.Join("/proc", strconv.Itoa(pid), "task"))
		if err != nil {
			return
		}
		for _, t := range tasks {
			b, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "task", t.Name(), "children"))
			if err != nil {
				continue
			}
			for _, f := range strings.Fields(string(b)) {
				if c, err := strconv.Atoi(f); err == nil {
					walk(c)
				}
			}
		}
	}
	walk(root)
	return out
}

// readStat returns utime, stime (in clock ticks) and the thread count.
func readStat(pid int) (utime, stime float64, threads int, ok bool) {
	b, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
	if err != nil {
		return 0, 0, 0, false
	}
	s := string(b)
	// comm (field 2) is parenthesised and may contain spaces and ')', so cut at
	// the LAST ')' and index the remaining fields from the state field on.
	i := strings.LastIndex(s, ")")
	if i < 0 || i+2 >= len(s) {
		return 0, 0, 0, false
	}
	f := strings.Fields(s[i+2:])
	// f[0] is state (field 3). utime is field 14 -> f[11]; stime 15 -> f[12];
	// num_threads 20 -> f[17].
	if len(f) < 18 {
		return 0, 0, 0, false
	}
	utime, _ = strconv.ParseFloat(f[11], 64)
	stime, _ = strconv.ParseFloat(f[12], 64)
	threads, _ = strconv.Atoi(f[17])
	return utime, stime, threads, true
}

func readRSS(pid int) int {
	b, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "status"))
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "VmRSS:") {
			f := strings.Fields(line)
			if len(f) >= 2 {
				v, _ := strconv.Atoi(f[1])
				return v
			}
		}
	}
	return 0
}
