// Command greet is a tiny runnable program for exercising
// :ArdangoDebug package (ardango.debug.curr_package / <leader>dP). That
// command runs `dlv debug`, which only works on a `package main` — the
// rest of the fixture is library code (package testdata). Open this file,
// optionally set a breakpoint, then :ArdangoDebug package followed by
// :ArdangoDebug continue / into.
package main

import (
	"fmt"

	"ardango/dev/testdata"
)

func main() {
	people := []testdata.Person{
		{Name: "Ardan"},
		{Name: "Bill"},
	}
	for _, p := range people {
		fmt.Println(testdata.Greet(p))
	}
}
