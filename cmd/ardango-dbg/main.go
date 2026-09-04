// Command ardango-dbg is a thin proxy between ardango.nvim (Lua) and a
// headless Delve JSON-RPC server.
//
// Neovim spawns `dlv --headless --listen=127.0.0.1:PORT`, then spawns this
// process and talks to it over stdin/stdout with a line protocol: one JSON
// request object per line in, one JSON response object per line out
// (json.Encoder writes a trailing newline after each). All Delve wire
// framing/RPC lives in delve's own service/rpc2 client, so there is no
// protocol code here or on the Lua side.
//
// Requests (Neovim -> here):
//
//	{"id":1,"op":"connect","addr":"127.0.0.1:43210"}
//	{"id":2,"op":"break","file":"/abs/f.go","line":42}
//	{"id":3,"op":"clearbreak","file":"/abs/f.go","line":42}
//	{"id":4,"op":"continue"}                 // also: next, step, stepout
//	{"id":5,"op":"stop"}
//
// Responses (here -> Neovim), always echoing the request id:
//
//	{"id":2,"ok":true,"breakpoint":{"id":1,"file":"...","line":42}}
//	{"id":4,"ok":true,"stopped":{"file":"...","line":43,"reason":"breakpoint","goroutine":6,"function":"pkg.Foo"}}
//	{"id":4,"ok":true,"terminated":{"exitStatus":0}}
//	{"id":1,"ok":false,"error":"dial tcp ...: connection refused"}
//
// continue/next/step/stepout run asynchronously: the response for that id
// is sent when the program next stops (or exits). Only one such command
// may be in flight at a time.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/go-delve/delve/service/api"
	"github.com/go-delve/delve/service/rpc2"
)

// Delve reports "the process finished during continue/step" as an RPC
// error string (not a DebuggerState with Exited=true), e.g.
// "Process 12345 has exited with status 0". Match it so we can turn it
// into a clean `terminated` response.
var procExitedRe = regexp.MustCompile(`has exited with status (-?\d+)`)

func exitStatus(err error) (int, bool) {
	if err == nil {
		return 0, false
	}
	m := procExitedRe.FindStringSubmatch(err.Error())
	if m == nil {
		return 0, false
	}
	n, _ := strconv.Atoi(m[1])
	return n, true
}

type request struct {
	ID        int    `json:"id"`
	Op        string `json:"op"`
	Addr      string `json:"addr"`
	File      string `json:"file"`
	Line      int    `json:"line"`
	Expr      string `json:"expr"`      // op "eval"
	Frame     int    `json:"frame"`     // op "eval"/"locals": stack frame, 0 = innermost
	Depth     int    `json:"depth"`     // op "stack": max frames
	Goroutine int64  `json:"goroutine"` // op "switchgoroutine"
	Cond      string `json:"cond"`      // op "break": optional condition expression
}

// How much to load when evaluating an explicit expression - generous
// enough for a hover popup without pulling unbounded data.
var evalLoadConfig = api.LoadConfig{
	FollowPointers:     true,
	MaxVariableRecurse: 2,
	MaxStringLen:       512,
	MaxArrayValues:     128,
	MaxStructFields:    -1,
}

// Much shallower for the "list what's in scope" command - one line per
// var, so a *testing.T mustn't expand to a 4KB line.
var localsLoadConfig = api.LoadConfig{
	FollowPointers:     true,
	MaxVariableRecurse: 1,
	MaxStringLen:       128,
	MaxArrayValues:     16,
	MaxStructFields:    10,
}

type bpInfo struct {
	ID   int    `json:"id"`
	File string `json:"file"`
	Line int    `json:"line"`
}

type stopInfo struct {
	File      string `json:"file"`
	Line      int    `json:"line"`
	Reason    string `json:"reason"`
	Goroutine int64  `json:"goroutine"`
	Function  string `json:"function"`
}

type termInfo struct {
	ExitStatus int `json:"exitStatus"`
}

type frameInfo struct {
	File     string `json:"file"`
	Line     int    `json:"line"`
	Function string `json:"function"`
}

type goroutineInfo struct {
	ID       int64  `json:"id"`
	Current  bool   `json:"current"`
	Status   string `json:"status"`
	Function string `json:"function"`
	File     string `json:"file"`
	Line     int    `json:"line"`
}

type response struct {
	ID         int             `json:"id"`
	OK         bool            `json:"ok"`
	Error      string          `json:"error,omitempty"`
	Breakpoint *bpInfo         `json:"breakpoint,omitempty"`
	Stopped    *stopInfo       `json:"stopped,omitempty"`
	Terminated *termInfo       `json:"terminated,omitempty"`
	Lines      []string        `json:"lines,omitempty"`  // op "eval"/"locals": rendered text
	Frames     []frameInfo     `json:"frames,omitempty"` // op "stack"
	Goroutines []goroutineInfo `json:"goroutines,omitempty"`
	Truncated  bool            `json:"truncated,omitempty"` // op "goroutines": more than the cap
}

type server struct {
	writeMu sync.Mutex // serializes stdout writes
	enc     *json.Encoder

	mu       sync.Mutex // guards client, bps, busy, stopping
	client   *rpc2.RPCClient
	bps      map[string]int // "file:line" -> delve breakpoint id
	busy     bool           // a continue/next/step/stepout is in flight
	stopping bool           // a "stop" is being handled; suppress further output
}

func key(file string, line int) string {
	return fmt.Sprintf("%s:%d", file, line)
}

func (s *server) send(r response) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_ = s.enc.Encode(r)
}

func (s *server) fail(id int, err error) {
	s.send(response{ID: id, OK: false, Error: err.Error()})
}

func (s *server) handle(req request) {
	switch req.Op {
	case "connect":
		s.connect(req)
	case "break":
		s.setBreak(req)
	case "clearbreak":
		s.clearBreak(req)
	case "continue", "next", "step", "stepout":
		s.run(req)
	case "eval":
		s.evalVar(req)
	case "locals":
		s.listLocals(req)
	case "stack":
		s.stackTrace(req)
	case "goroutines":
		s.listGoroutines(req)
	case "switchgoroutine":
		s.switchGoroutine(req)
	case "stop":
		s.mu.Lock()
		s.stopping = true
		c := s.client
		s.mu.Unlock()
		if c != nil {
			_, _ = c.Halt()
			_ = c.Detach(true)
		}
		// Halt unblocks any in-flight run goroutine; let it unwind (its
		// deferred `busy = false` runs after its final send) before we
		// exit, so os.Exit can't kill it mid-Encode.
		for i := 0; i < 200; i++ {
			s.mu.Lock()
			busy := s.busy
			s.mu.Unlock()
			if !busy {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		s.send(response{ID: req.ID, OK: true})
		os.Exit(0)
	default:
		s.fail(req.ID, fmt.Errorf("unknown op %q", req.Op))
	}
}

// connect dials the headless dlv server itself (rather than rpc2.NewClient,
// which panics on a failed dial) so a refused/slow connection is a normal
// error response.
func (s *server) connect(req request) {
	conn, err := net.DialTimeout("tcp", req.Addr, 5*time.Second)
	if err != nil {
		s.fail(req.ID, err)
		return
	}
	client := rpc2.NewClientFromConn(conn)
	if _, err := client.GetStateNonBlocking(); err != nil {
		s.fail(req.ID, fmt.Errorf("connected but state check failed: %w", err))
		return
	}
	s.mu.Lock()
	s.client = client
	s.mu.Unlock()
	s.send(response{ID: req.ID, OK: true})
}

func (s *server) setBreak(req request) {
	s.mu.Lock()
	client := s.client
	s.mu.Unlock()
	if client == nil {
		s.fail(req.ID, fmt.Errorf("not connected"))
		return
	}
	bp, err := client.CreateBreakpoint(&api.Breakpoint{File: req.File, Line: req.Line, Cond: req.Cond})
	if err != nil {
		s.fail(req.ID, err)
		return
	}
	// Key by the line dlv actually planted it on, not the one we asked
	// for: dlv snaps forward to the next line with code, and clearBreak
	// (and the editor's sign) track that reported line.
	s.mu.Lock()
	s.bps[key(req.File, bp.Line)] = bp.ID
	s.mu.Unlock()
	s.send(response{ID: req.ID, OK: true, Breakpoint: &bpInfo{ID: bp.ID, File: bp.File, Line: bp.Line}})
}

func (s *server) clearBreak(req request) {
	s.mu.Lock()
	client := s.client
	id, ok := s.bps[key(req.File, req.Line)]
	s.mu.Unlock()
	if client == nil {
		s.fail(req.ID, fmt.Errorf("not connected"))
		return
	}
	if !ok {
		s.fail(req.ID, fmt.Errorf("no breakpoint at %s", key(req.File, req.Line)))
		return
	}
	if _, err := client.ClearBreakpoint(id); err != nil {
		s.fail(req.ID, err)
		return
	}
	s.mu.Lock()
	delete(s.bps, key(req.File, req.Line))
	s.mu.Unlock()
	s.send(response{ID: req.ID, OK: true})
}

// evalVar evaluates req.Expr in the given stack frame of the current
// goroutine and returns Delve's own pretty-printed rendering as lines.
// Only valid on a halted target.
func (s *server) evalVar(req request) {
	s.mu.Lock()
	client := s.client
	busy := s.busy
	s.mu.Unlock()
	if client == nil {
		s.fail(req.ID, fmt.Errorf("not connected"))
		return
	}
	if busy {
		s.fail(req.ID, fmt.Errorf("target is running"))
		return
	}

	scope := api.EvalScope{GoroutineID: -1, Frame: req.Frame}
	v, err := client.EvalVariable(scope, req.Expr, evalLoadConfig)
	if err != nil {
		s.fail(req.ID, err)
		return
	}

	rendered := v.StringWithOptions("    ", "", api.PrettyNewlines|api.PrettyShortenType)
	if rendered == "" {
		rendered = "(no value)"
	}
	valueLines := strings.Split(strings.TrimRight(rendered, "\n"), "\n")

	// "<type> = <value>" for a scalar, "<type> =" + value lines for a
	// composite. Untyped values (v.Type == "", e.g. `1+1`) get just the
	// value, no "type =" preamble.
	var lines []string
	switch {
	case v.Type == "":
		lines = valueLines
	case len(valueLines) == 1:
		lines = []string{v.Type + " = " + valueLines[0]}
	default:
		lines = append([]string{v.Type + " ="}, valueLines...)
	}
	s.send(response{ID: req.ID, OK: true, Lines: lines})
}

// listLocals renders the given frame's function arguments and local
// variables as "name = value" lines. Halted target only.
func (s *server) listLocals(req request) {
	s.mu.Lock()
	client := s.client
	busy := s.busy
	s.mu.Unlock()
	if client == nil {
		s.fail(req.ID, fmt.Errorf("not connected"))
		return
	}
	if busy {
		s.fail(req.ID, fmt.Errorf("target is running"))
		return
	}

	scope := api.EvalScope{GoroutineID: -1, Frame: req.Frame}
	args, err := client.ListFunctionArgs(scope, localsLoadConfig)
	if err != nil {
		s.fail(req.ID, err)
		return
	}
	locals, err := client.ListLocalVariables(scope, localsLoadConfig)
	if err != nil {
		s.fail(req.ID, err)
		return
	}

	// Delve lists a function's result slots (~r0, ~r1, ...) among its
	// args. They're zero until the function returns, so before then they're
	// noise; once stopped on/after the return they hold the actual return
	// values - either way they belong under their own header, not "args".
	var plainArgs, returns []api.Variable
	for _, v := range args {
		if strings.HasPrefix(v.Name, "~") {
			returns = append(returns, v)
		} else {
			plainArgs = append(plainArgs, v)
		}
	}

	var lines []string
	section := func(header string, vars []api.Variable) {
		if len(vars) == 0 {
			return
		}
		lines = append(lines, header)
		for _, v := range vars {
			lines = append(lines, "  "+v.Name+" = "+v.SinglelineString())
		}
	}
	section("-- args --", plainArgs)
	section("-- locals --", locals)
	section("-- returns --", returns)
	if len(lines) == 0 {
		lines = []string{"(no variables in scope)"}
	}
	s.send(response{ID: req.ID, OK: true, Lines: lines})
}

// stackTrace returns the current goroutine's call stack as structured
// frames (Neovim formats + navigates them). Halted target only.
func (s *server) stackTrace(req request) {
	s.mu.Lock()
	client := s.client
	busy := s.busy
	s.mu.Unlock()
	if client == nil {
		s.fail(req.ID, fmt.Errorf("not connected"))
		return
	}
	if busy {
		s.fail(req.ID, fmt.Errorf("target is running"))
		return
	}

	depth := req.Depth
	if depth <= 0 {
		depth = 50
	}
	frames, err := client.Stacktrace(-1, depth, 0, 0, &evalLoadConfig)
	if err != nil {
		s.fail(req.ID, err)
		return
	}

	out := make([]frameInfo, 0, len(frames))
	for _, f := range frames {
		fn := "?"
		if f.Function != nil {
			fn = f.Function.Name()
		}
		out = append(out, frameInfo{File: f.File, Line: f.Line, Function: fn})
	}
	s.send(response{ID: req.ID, OK: true, Frames: out})
}

// Common runtime.waitReason values (runtime/runtime2.go). Not exhaustive -
// unknowns fall back to the bare "waiting" status.
var waitReasons = map[int64]string{
	2:  "chan receive (nil chan)",
	3:  "chan send (nil chan)",
	7:  "GC sweep wait",
	8:  "chan receive",
	9:  "chan send",
	11: "select",
	14: "sync.Mutex.Lock",
	15: "sync.WaitGroup.Wait",
	16: "sync.Cond.Wait",
	20: "IO wait",
	22: "timer",
	26: "sleep",
	27: "sync.RWMutex.RLock",
	28: "sync.RWMutex.Lock",
}

// Go runtime goroutine status (runtime/runtime2.go gStatus); api.Goroutine
// exposes it as a raw number, sometimes OR'd with _Gscan (0x1000).
func goroutineStatus(n uint64, waitReason int64) string {
	scanning := ""
	if n&0x1000 != 0 {
		scanning = " (scan)"
		n &^= 0x1000
	}
	switch n {
	case 0:
		return "idle" + scanning
	case 1:
		return "runnable" + scanning
	case 2:
		return "running" + scanning
	case 3:
		return "syscall" + scanning
	case 4:
		if wr := waitReasons[waitReason]; wr != "" {
			return wr + scanning
		}
		return "waiting" + scanning
	case 6:
		return "dead" + scanning
	case 8:
		return "copystack" + scanning
	case 9:
		return "preempted" + scanning
	default:
		return fmt.Sprintf("status %d%s", n, scanning)
	}
}

func locFunc(loc api.Location) string {
	if loc.Function != nil {
		return loc.Function.Name()
	}
	return "?"
}

// listGoroutines returns every goroutine with its user-code location and
// status, flagging the currently selected one. Halted target only.
func (s *server) listGoroutines(req request) {
	s.mu.Lock()
	client := s.client
	busy := s.busy
	s.mu.Unlock()
	if client == nil {
		s.fail(req.ID, fmt.Errorf("not connected"))
		return
	}
	if busy {
		s.fail(req.ID, fmt.Errorf("target is running"))
		return
	}

	const limit = 500
	gs, nextg, err := client.ListGoroutines(0, limit)
	if err != nil {
		s.fail(req.ID, err)
		return
	}

	var cur int64 = -1
	if st, err := client.GetState(); err == nil && st != nil && st.SelectedGoroutine != nil {
		cur = st.SelectedGoroutine.ID
	}

	out := make([]goroutineInfo, 0, len(gs))
	for _, g := range gs {
		out = append(out, goroutineInfo{
			ID:       g.ID,
			Current:  g.ID == cur,
			Status:   goroutineStatus(g.Status, g.WaitReason),
			Function: locFunc(g.UserCurrentLoc),
			File:     g.UserCurrentLoc.File,
			Line:     g.UserCurrentLoc.Line,
		})
	}
	// nextg > 0 is the resume index when ListGoroutines had more to give
	// past the limit (it's 0 or -1 when the list is complete).
	s.send(response{ID: req.ID, OK: true, Goroutines: out, Truncated: nextg > 0})
}

// switchGoroutine makes req.Goroutine the selected goroutine; the response
// carries its user-code location so Neovim can move the position sign.
func (s *server) switchGoroutine(req request) {
	s.mu.Lock()
	client := s.client
	busy := s.busy
	s.mu.Unlock()
	if client == nil {
		s.fail(req.ID, fmt.Errorf("not connected"))
		return
	}
	if busy {
		s.fail(req.ID, fmt.Errorf("target is running"))
		return
	}

	st, err := client.SwitchGoroutine(req.Goroutine)
	if err != nil {
		s.fail(req.ID, err)
		return
	}

	si := &stopInfo{Reason: "goroutine switch", Goroutine: req.Goroutine}
	if g := st.SelectedGoroutine; g != nil {
		si.Goroutine = g.ID
		si.File = g.UserCurrentLoc.File
		si.Line = g.UserCurrentLoc.Line
		si.Function = locFunc(g.UserCurrentLoc)
	}
	s.send(response{ID: req.ID, OK: true, Stopped: si})
}

func (s *server) run(req request) {
	s.mu.Lock()
	client := s.client
	if client == nil {
		s.mu.Unlock()
		s.fail(req.ID, fmt.Errorf("not connected"))
		return
	}
	if s.busy {
		s.mu.Unlock()
		s.fail(req.ID, fmt.Errorf("a run command is already in progress"))
		return
	}
	s.busy = true
	s.mu.Unlock()

	go func() {
		defer func() {
			s.mu.Lock()
			s.busy = false
			s.mu.Unlock()
		}()

		var st *api.DebuggerState
		var err error
		switch req.Op {
		case "continue":
			st = <-client.Continue()
			if st != nil {
				err = st.Err
			}
		case "next":
			st, err = client.Next()
		case "step":
			st, err = client.Step()
		case "stepout":
			st, err = client.StepOut()
		}

		// If a "stop" landed while this was running, its result is moot
		// and Neovim's session is already gone - don't emit a stray line.
		s.mu.Lock()
		stopping := s.stopping
		s.mu.Unlock()
		if stopping {
			return
		}

		if code, ok := exitStatus(err); ok {
			s.send(response{ID: req.ID, OK: true, Terminated: &termInfo{ExitStatus: code}})
			return
		}
		if err != nil {
			s.fail(req.ID, err)
			return
		}
		if st == nil {
			s.fail(req.ID, fmt.Errorf("nil debugger state"))
			return
		}
		if st.Exited {
			s.send(response{ID: req.ID, OK: true, Terminated: &termInfo{ExitStatus: st.ExitStatus}})
			return
		}
		s.send(response{ID: req.ID, OK: true, Stopped: stopFrom(st)})
	}()
}

func stopFrom(st *api.DebuggerState) *stopInfo {
	si := &stopInfo{Reason: st.StopReason}
	if st.SelectedGoroutine != nil {
		si.Goroutine = st.SelectedGoroutine.ID
	}
	if th := st.CurrentThread; th != nil {
		si.File = th.File
		si.Line = th.Line
		if th.GoroutineID != 0 {
			si.Goroutine = th.GoroutineID
		}
		if th.Function != nil {
			si.Function = th.Function.Name()
		}
	}
	return si
}

func main() {
	s := &server{
		enc: json.NewEncoder(os.Stdout),
		bps: make(map[string]int),
	}

	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var req request
		if err := json.Unmarshal(line, &req); err != nil {
			s.send(response{OK: false, Error: fmt.Sprintf("bad request: %v", err)})
			continue
		}
		s.handle(req)
	}

	// stdin closed - Neovim is gone, possibly without sending "stop" (a
	// crash / SIGKILL). Kill the debuggee so it doesn't outlive us, but
	// don't hang here if dlv is unresponsive.
	s.mu.Lock()
	s.stopping = true
	c := s.client
	s.mu.Unlock()
	if c != nil {
		_, _ = c.Halt()
	}
	// Let an in-flight run goroutine unwind first, as the "stop" op does -
	// Halt() above is what actually unblocks it.
	for i := 0; i < 200; i++ {
		s.mu.Lock()
		busy := s.busy
		s.mu.Unlock()
		if !busy {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if c != nil {
		done := make(chan struct{})
		go func() { _ = c.Detach(true); close(done) }()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
		}
	}
	os.Exit(0)
}
