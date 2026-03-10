package shell

import (
	"strings"
	"testing"
)

func TestReplaceManagedBlockIsIdempotent(t *testing.T) {
	block := ManagedBlock("/tmp/nest/bin")
	updated := replaceManagedBlock("export EDITOR=vim\n", block)
	updated = replaceManagedBlock(updated, block)

	if strings.Count(updated, beginMarker) != 1 {
		t.Fatalf("expected one managed block, got %s", updated)
	}
	if !strings.Contains(updated, "/tmp/nest/bin") {
		t.Fatalf("expected bin path in managed block, got %s", updated)
	}
}
