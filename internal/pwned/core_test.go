package pwned

import "testing"

type fakeProvider map[string]int

func (f fakeProvider) Lookup(prefix, suffix string) (int, error) {
	return f[prefix+":"+suffix], nil
}

func TestHashParts(t *testing.T) {
	prefix, suffix := HashParts("password")
	if prefix != "5BAA6" {
		t.Fatalf("prefix = %q, want 5BAA6", prefix)
	}
	if len(suffix) != 35 {
		t.Fatalf("suffix length = %d, want 35", len(suffix))
	}
}

func TestValidateCleanPassword(t *testing.T) {
	result, err := Validate("not-in-fixture", fakeProvider{})
	if err != nil {
		t.Fatal(err)
	}
	if result.Pwned || result.Count != 0 {
		t.Fatalf("result = %+v, want clean", result)
	}
}

func TestValidatePwnedPassword(t *testing.T) {
	prefix, suffix := HashParts("password")
	result, err := Validate("password", fakeProvider{prefix + ":" + suffix: 42})
	if err != nil {
		t.Fatal(err)
	}
	if !result.Pwned || result.Count != 42 {
		t.Fatalf("result = %+v, want pwned count 42", result)
	}
}
