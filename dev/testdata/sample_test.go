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
