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
	ID    int    `json:"id"`
	Op    string `json:"op"`
	Addr  string `json:"addr"`
	File  string `json:"file"`
	Line  int    `json:"line"`
	Expr  string `json:"expr"`  // op "eval"
	Frame int    `json:"frame"` // op "eval"/"locals": stack frame, 0 = innermost
	Depth int    `json:"depth"` // op "stack": max frames
}

// How much to load when evaluating an expression - generous enough for a
// hover popup without pulling unbounded data.
var evalLoadConfig = api.LoadConfig{
	FollowPointers:     true,
	MaxVariableRecurse: 2,
	MaxStringLen:       512,
	MaxArrayValues:     128,
	MaxStructFields:    -1,
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

type response struct {
	ID         int       `json:"id"`
	OK         bool      `json:"ok"`
	Error      string    `json:"error,omitempty"`
	Breakpoint *bpInfo   `json:"breakpoint,omitempty"`
	Stopped    *stopInfo `json:"stopped,omitempty"`
	Terminated *termInfo `json:"terminated,omitempty"`
	Lines      []string  `json:"lines,omitempty"` // op "eval"/"locals"/"stack": rendered text
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
	bp, err := client.CreateBreakpoint(&api.Breakpoint{File: req.File, Line: req.Line})
	if err != nil {
		s.fail(req.ID, err)
		return
	}
	s.mu.Lock()
	s.bps[key(req.File, req.Line)] = bp.ID
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
	valueLines := strings.Split(strings.TrimRight(rendered, "\n"), "\n")

	var lines []string
	if len(valueLines) == 1 {
		// Scalar / compact value - keep it on one line, LSP-hover style.
		lines = []string{v.Type + " = " + valueLines[0]}
	} else {
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
	args, err := client.ListFunctionArgs(scope, evalLoadConfig)
	if err != nil {
		s.fail(req.ID, err)
		return
	}
	locals, err := client.ListLocalVariables(scope, evalLoadConfig)
	if err != nil {
		s.fail(req.ID, err)
		return
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
	section("-- args --", args)
	section("-- locals --", locals)
	if len(lines) == 0 {
		lines = []string{"(no variables in scope)"}
	}
	s.send(response{ID: req.ID, OK: true, Lines: lines})
}

// stackTrace renders the current goroutine's call stack. Lines lead with
// "file:line" so Neovim's results popup can jump to a frame on <CR>.
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

	lines := make([]string, 0, len(frames))
	for i, f := range frames {
		fn := "?"
		if f.Function != nil {
			fn = f.Function.Name()
		}
		lines = append(lines, fmt.Sprintf("%s:%d  #%d  %s", f.File, f.Line, i, fn))
	}
	if len(lines) == 0 {
		lines = []string{"(empty stack)"}
	}
	s.send(response{ID: req.ID, OK: true, Lines: lines})
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
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
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
}
