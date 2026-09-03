// Command cgohello deliberately uses cgo, so building it runs the C
// toolchain. It exists to exercise one NixOS-specific failure: inside
// `nix develop` (fortify hardening on), `dlv debug` / `dlv test` compile
// the C without -O and the build dies with
//
//	error: #warning _FORTIFY_SOURCE requires compiling with optimization
//
// which surfaces as "could not launch process: not an executable file".
// The fix is debug.env = { CGO_CFLAGS = "-O2" } in setup() (CGO_ENABLED =
// "0" is not an option here - this package genuinely needs cgo). See the
// :ArdangoDebug package rows in TESTING.md.
package main

/*
static int c_answer(void) { return 42; }
*/
import "C"

import "fmt"

func main() {
	// Value comes back through Go's fmt, not C stdio: Go's exit path
	// doesn't flush C's stdout buffer, so a C puts/printf would be lost
	// when stdout isn't a tty.
	fmt.Println("cgo answer:", int(C.c_answer()))
}
