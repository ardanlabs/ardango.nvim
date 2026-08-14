package testdata

// Person is a sample struct used to exercise the struct-tag commands
// (AddTagToField, AddTagsToStruct, RemoveTagFromField, RemoveTagsFromStruct).
type Person struct {
	Name  string
	Age   int
	Email string
}

// Greet returns a greeting for the given person.
func Greet(p Person) string {
	return "hello, " + p.Name
}
