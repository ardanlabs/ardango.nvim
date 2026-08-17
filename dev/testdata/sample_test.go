package testdata

import "testing"

// TestGreetPass is the "everything is fine" path: put the cursor inside
// this function and run RunCurrTest to see the success notification.
func TestGreetPass(t *testing.T) {
	got := Greet(Person{Name: "Ardan"})
	want := "hello, Ardan"
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

// TestGreetFail is intentionally wrong: put the cursor inside this
// function and run RunCurrTest to see the failure land in the quickfix list.
func TestGreetFail(t *testing.T) {
	got := Greet(Person{Name: "Ardan"})
	want := "goodbye, Ardan"
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

// TestManyMixed is a table-driven test with a pile of subtests, most
// failing but some passing, purely to produce enough output to see how
// the popup/quickfix/telescope views handle content taller than the
// window (scrolling, etc) and a realistic pass/fail mix in opts.verbose.
func TestManyMixed(t *testing.T) {
	cases := []struct {
		name string
		want string
	}{
		{"case 01", "not Ardan 01"},
		{"case 02", "not Ardan 02"},
		{"case 03", "not Ardan 03"},
		{"case 04", "hello, Ardan"},
		{"case 05", "not Ardan 05"},
		{"case 06", "not Ardan 06"},
		{"case 07", "not Ardan 07"},
		{"case 08", "hello, Ardan"},
		{"case 09", "not Ardan 09"},
		{"case 10", "not Ardan 10"},
		{"case 11", "not Ardan 11"},
		{"case 12", "hello, Ardan"},
		{"case 13", "not Ardan 13"},
		{"case 14", "not Ardan 14"},
		{"case 15", "not Ardan 15"},
		{"case 16", "hello, Ardan"},
		{"case 17", "not Ardan 17"},
		{"case 18", "not Ardan 18"},
		{"case 19", "not Ardan 19"},
		{"case 20", "hello, Ardan"},
	}

	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			got := Greet(Person{Name: "Ardan"})
			if got != c.want {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
}

// BenchmarkGreet is a plain benchmark: put the cursor inside it and run
// RunCurrBenchmark to see the ns/op and allocation stats.
func BenchmarkGreet(b *testing.B) {
	p := Person{Name: "Ardan"}
	for i := 0; i < b.N; i++ {
		Greet(p)
	}
}
