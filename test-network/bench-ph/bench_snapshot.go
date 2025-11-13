package main

import (
	"crypto/sha256"
	"encoding/csv"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"sort"
	"strconv"
	"strings"
	"time"

	ph "go-parallelhash/hash"
)

type row struct {
	Algo       string
	Bbytes     int
	File       string
	Bytes      int64
	ElapsedMs  float64
	Throughput float64 // MiB/s
	SumHex     string
}

// --- utils ---

func parseSize(s string) (int, error) {
	// accepts plain numbers (e.g. "1048576") or with suffixes K/M/G
	s = strings.TrimSpace(strings.ToUpper(s))
	mult := 1
	switch {
	case strings.HasSuffix(s, "K"):
		mult = 1 << 10
		s = strings.TrimSuffix(s, "K")
	case strings.HasSuffix(s, "M"):
		mult = 1 << 20
		s = strings.TrimSuffix(s, "M")
	case strings.HasSuffix(s, "G"):
		mult = 1 << 30
		s = strings.TrimSuffix(s, "G")
	}
	v, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil {
		return 0, err
	}
	return v * mult, nil
}

func parseBs(list string) ([]int, error) {
	parts := strings.Split(list, ",")
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		if strings.TrimSpace(p) == "" {
			continue
		}
		v, err := parseSize(p)
		if err != nil {
			return nil, fmt.Errorf("failed to parse B '%s': %w", p, err)
		}
		out = append(out, v)
	}
	if len(out) == 0 {
		// default: 1 MiB
		out = []int{1 << 20}
	}
	return out, nil
}

func medianFloat64(xs []float64) float64 {
	if len(xs) == 0 {
		return 0
	}
	cp := append([]float64(nil), xs...)
	sort.Float64s(cp)
	m := len(cp) / 2
	if len(cp)%2 == 1 {
		return cp[m]
	}
	return (cp[m-1] + cp[m]) / 2.0
}

// --- bench helpers ---

func benchOnceBytes(name string, fname string, data []byte, f func([]byte) []byte, B int) row {
	start := time.Now()
	sum := f(data)
	el := time.Since(start)
	mb := float64(len(data)) / (1024.0 * 1024.0)
	sumHex := fmt.Sprintf("%x", sum)
	return row{
		Algo:       name,
		Bbytes:     B,
		File:       fname,
		Bytes:      int64(len(data)),
		ElapsedMs:  float64(el.Microseconds()) / 1000.0,
		Throughput: mb / el.Seconds(),
		SumHex:     sumHex,
	}
}

func benchMedian(name string, B int, fname string, data []byte, n int, f func([]byte) []byte) row {
	elList := make([]float64, 0, n)
	var last row
	for i := 0; i < n; i++ {
		r := benchOnceBytes(name, fname, data, f, B)
		last = r
		elList = append(elList, r.ElapsedMs)
	}
	medMs := medianFloat64(elList)
	mb := float64(len(data)) / (1024.0 * 1024.0)
	sec := medMs / 1000.0
	thr := 0.0
	if sec > 0 {
		thr = mb / sec
	}
	last.ElapsedMs = medMs
	last.Throughput = thr
	return last
}

// --- main ---

func main() {
	var (
		outCSV    string
		BsStr     string
		Lbits     int
		S         string
		nRep      int
		doConcat  bool
		procs     int
		algoSel   string

		// profile output paths (empty = disabled)
		cpuProfPath   string
		memProfPath   string
		blockProfPath string
		mutexProfPath string
		gorProfPath    string
		threadProfPath string
		blockRate     int
		mutexRate     int
	)

	flag.StringVar(&outCSV, "out", "snapshot_bench.csv", "output CSV file")
	flag.StringVar(&BsStr, "Bs", "auto", "List of B (e.g. \"256K,1M,4M\" or \"auto\" = len(X)/GOMAXPROCS)")
	flag.IntVar(&Lbits, "L", 256, "PH output length (bits)")
	flag.StringVar(&S, "cust", "", "PH customization string")
	flag.IntVar(&nRep, "n", 5, "Repetitions per measurement (median is used)")
	flag.BoolVar(&doConcat, "concat", true, "Concatenate all files and also measure a _all.data")
	flag.IntVar(&procs, "procs", 0, "Fix GOMAXPROCS (0 = keep default)")
	flag.StringVar(&algoSel, "algo", "both", "Which algorithm to run: both | sha | ph")

	flag.StringVar(&cpuProfPath, "cpuprof", "", "CPU profile output file (empty to disable)")
	flag.StringVar(&memProfPath, "memprof", "", "Heap/memory profile output file (empty to disable)")
	flag.StringVar(&blockProfPath, "blockprof", "", "Block profile output file (empty to disable)")
	flag.StringVar(&mutexProfPath, "mutexprof", "", "Mutex profile output file (empty to disable)")
	flag.StringVar(&gorProfPath, "gorprof", "", "Goroutine profile output file (empty to disable)")
	flag.StringVar(&threadProfPath, "threadprof", "", "Thread-create profile output file (empty to disable)")
	flag.IntVar(&blockRate, "blockrate", 0, "Block profile rate (0 = disable)")
	flag.IntVar(&mutexRate, "mutexrate", 0, "Mutex profile rate (0 = disable)")

	flag.Parse()

	algoSel = strings.ToLower(strings.TrimSpace(algoSel))
	if algoSel != "both" && algoSel != "sha" && algoSel != "ph" {
		fmt.Fprintf(os.Stderr, "invalid value for -algo: %s (use: both|sha|ph)\n", algoSel)
		os.Exit(2)
	}

	if procs > 0 {
		runtime.GOMAXPROCS(procs)
	}

	if flag.NArg() == 0 {
		fmt.Fprintln(os.Stderr, "usage: go run bench_snapshot.go [flags] <.data files...>")
		flag.PrintDefaults()
		os.Exit(2)
	}

	// --- Profiles ---
	// The program supports writing several pprof profiles. These are optional
	// and controlled by command-line flags. When enabled, files are created and
	// the appropriate pprof APIs are used to capture profiles.
	// CPU profile
	if cpuProfPath != "" {
		f, err := os.Create(cpuProfPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "error creating cpu profile: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("CPU profile -> %s\n", cpuProfPath)
		if err := pprof.StartCPUProfile(f); err != nil {
			fmt.Fprintf(os.Stderr, "error StartCPUProfile: %v\n", err)
			f.Close()
			os.Exit(1)
		}
		defer func() {
			pprof.StopCPUProfile()
			f.Close()
		}()
	}

	// Heap / memory profile
	if memProfPath != "" {
		defer func() {
			f, err := os.Create(memProfPath)
			if err != nil {
				fmt.Fprintf(os.Stderr, "error creating mem profile: %v\n", err)
				return
			}
			fmt.Printf("Heap/mem profile -> %s\n", memProfPath)
			// força GC antes do snapshot de heap
			// force GC before taking the heap snapshot to get a more accurate view
			runtime.GC()
			if err := pprof.WriteHeapProfile(f); err != nil {
				fmt.Fprintf(os.Stderr, "error WriteHeapProfile: %v\n", err)
			}
			f.Close()
		}()
	}

	// Block profile
	if blockRate > 0 {
		fmt.Printf("Block profile enabled (rate=%d)\n", blockRate)
		runtime.SetBlockProfileRate(blockRate)
		if blockProfPath != "" {
			defer func() {
				p := pprof.Lookup("block")
				if p == nil {
					fmt.Fprintf(os.Stderr, "block profile not found\n")
					return
				}
				f, err := os.Create(blockProfPath)
				if err != nil {
					fmt.Fprintf(os.Stderr, "error creating block profile: %v\n", err)
					return
				}
				fmt.Printf("Block profile -> %s\n", blockProfPath)
				// Write profile: 0 = text, 1 = pprof binary
				if err := p.WriteTo(f, 0); err != nil {
					fmt.Fprintf(os.Stderr, "error writing block profile: %v\n", err)
				}
				f.Close()
			}()
		}
	}

	// Mutex profile
	if mutexRate > 0 {
		fmt.Printf("Mutex profile enabled (rate=%d)\n", mutexRate)
		runtime.SetMutexProfileFraction(mutexRate)
		if mutexProfPath != "" {
			defer func() {
				p := pprof.Lookup("mutex")
				if p == nil {
					fmt.Fprintf(os.Stderr, "mutex profile not found\n")
					return
				}
				f, err := os.Create(mutexProfPath)
				if err != nil {
					fmt.Fprintf(os.Stderr, "error creating mutex profile: %v\n", err)
					return
				}
				fmt.Printf("Mutex profile -> %s\n", mutexProfPath)
				if err := p.WriteTo(f, 0); err != nil {
					fmt.Fprintf(os.Stderr, "error writing mutex profile: %v\n", err)
				}
				f.Close()
			}()
		}
	}

	// Goroutine profile (snapshot at the end)
	if gorProfPath != "" {
		defer func() {
			p := pprof.Lookup("goroutine")
			if p == nil {
				fmt.Fprintf(os.Stderr, "goroutine profile not found\n")
				return
			}
			f, err := os.Create(gorProfPath)
			if err != nil {
				fmt.Fprintf(os.Stderr, "error creating goroutine profile: %v\n", err)
				return
			}
			fmt.Printf("Goroutine profile -> %s\n", gorProfPath)
			// debug=0 => pprof binary format (same as cpu.prof)
			if err := p.WriteTo(f, 0); err != nil {
				fmt.Fprintf(os.Stderr, "error writing goroutine profile: %v\n", err)
			}
			f.Close()
		}()
	}

	// Thread-create profile
    if threadProfPath != "" {
        defer func() {
            p := pprof.Lookup("threadcreate")
            if p == nil {
				fmt.Fprintf(os.Stderr, "threadcreate profile not found\n")
                return
            }
            f, err := os.Create(threadProfPath)
            if err != nil {
				fmt.Fprintf(os.Stderr, "error creating threadcreate profile: %v\n", err)
                return
            }
			fmt.Printf("Threadcreate profile -> %s\n", threadProfPath)
			if err := p.WriteTo(f, 0); err != nil {
				fmt.Fprintf(os.Stderr, "error writing threadcreate profile: %v\n", err)
			}
            f.Close()
        }()
    }

	// Load .data files into memory
	type inFile struct {
		name string
		data []byte
	}
	var inputs []inFile
	for _, p := range flag.Args() {
		b, err := os.ReadFile(p)
		if err != nil {
			fmt.Fprintf(os.Stderr, "error reading %s: %v\n", p, err)
			os.Exit(1)
		}
		inputs = append(inputs, inFile{name: filepath.Base(p), data: b})
	}

	// If BsStr == "auto", choose B = len(X)/GOMAXPROCS for _all.data
	// (this matches the earlier analysis where we slice the input per worker)
	Bs := []int{}
	if strings.ToLower(BsStr) == "auto" {
		// se concat estiver habilitado, vamos usar o total de _all.data para calcular B
		// If concatenation is enabled, use the total size of _all.data to compute B
		var total int
		for _, in := range inputs {
			total += len(in.data)
		}
		g := runtime.GOMAXPROCS(0)
		if g <= 0 {
			g = 1
		}
		B := total / g
		if B <= 0 {
			B = 1 << 20 // fallback 1 MiB
		}
		Bs = []int{B}
	} else {
		var err error
		Bs, err = parseBs(BsStr)
		if err != nil {
			fmt.Fprintf(os.Stderr, "error in -Bs: %v\n", err)
			os.Exit(1)
		}
	}

	// _all.data (concatenate in memory) if requested
	if doConcat && len(inputs) > 1 {
		var total int
		for _, f := range inputs {
			total += len(f.data)
		}
		buf := make([]byte, 0, total)
		for _, f := range inputs {
			buf = append(buf, f.data...)
		}
		inputs = append(inputs, inFile{name: "_all.data", data: buf})
	}

	// Prepare CSV output
	f, err := os.Create(outCSV)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error creating CSV: %v\n", err)
		os.Exit(1)
	}
	defer f.Close()
	w := csv.NewWriter(f)
	defer w.Flush()
	_ = w.Write([]string{"algo", "file", "B_bytes", "bytes", "elapsed_ms_med", "throughput_mib_s", "sum_hex"})

	for _, B := range Bs {
		var (
			totalBytesSHA int64
			totalBytesPH  int64
			elSHAms       []float64
			elPHms        []float64
		)

		for _, in := range inputs {

			// --- SHA-256 ---
			if algoSel == "both" || algoSel == "sha" {
				r1 := benchMedian("SHA-256", B, in.name, in.data, nRep, func(b []byte) []byte {
					h := sha256.Sum256(b)
					return h[:]
				})
				_ = w.Write([]string{
					r1.Algo, r1.File, fmt.Sprintf("%d", r1.Bbytes),
					fmt.Sprintf("%d", r1.Bytes),
					fmt.Sprintf("%.3f", r1.ElapsedMs),
					fmt.Sprintf("%.3f", r1.Throughput),
					r1.SumHex,
				})
				totalBytesSHA += r1.Bytes
				elSHAms = append(elSHAms, r1.ElapsedMs)
			}

			// --- PH128 ---
			if algoSel == "both" || algoSel == "ph" {
				r2 := benchMedian("PH128", B, in.name, in.data, nRep, func(b []byte) []byte {
					return ph.ParallelHash128Goroutines(b, B, Lbits, S)
				})
				_ = w.Write([]string{
					r2.Algo, r2.File, fmt.Sprintf("%d", r2.Bbytes),
					fmt.Sprintf("%d", r2.Bytes),
					fmt.Sprintf("%.3f", r2.ElapsedMs),
					fmt.Sprintf("%.3f", r2.Throughput),
					r2.SumHex,
				})
				totalBytesPH += r2.Bytes
				elPHms = append(elPHms, r2.ElapsedMs)
			}
		}

		// --- TOTAL SHA-256 ---
		if (algoSel == "both" || algoSel == "sha") && len(elSHAms) > 0 {
			totalMB := float64(totalBytesSHA) / (1024.0 * 1024.0)
			shaMed := medianFloat64(elSHAms)
			shaThr := 0.0
			if shaMed > 0 {
				shaThr = totalMB / (shaMed / 1000.0)
			}
			_ = w.Write([]string{
				"SHA-256", "TOTAL", fmt.Sprintf("%d", B),
				fmt.Sprintf("%d", totalBytesSHA),
				fmt.Sprintf("%.3f", shaMed),
				fmt.Sprintf("%.3f", shaThr),
				"",
			})
		}

		// --- TOTAL PH128 ---
		if (algoSel == "both" || algoSel == "ph") && len(elPHms) > 0 {
			totalMB := float64(totalBytesPH) / (1024.0 * 1024.0)
			phMed := medianFloat64(elPHms)
			phThr := 0.0
			if phMed > 0 {
				phThr = totalMB / (phMed / 1000.0)
			}
			_ = w.Write([]string{
				"PH128", "TOTAL", fmt.Sprintf("%d", B),
				fmt.Sprintf("%d", totalBytesPH),
				fmt.Sprintf("%.3f", phMed),
				fmt.Sprintf("%.3f", phThr),
				"",
			})
		}

		// blank line separating different B values
		_ = w.Write([]string{})
	}

	fmt.Printf("OK! CSV saved at %s\n", outCSV)
}
