package mariadb

import "testing"

func TestArchiveArch(t *testing.T) {
	value := archiveArch()
	if value == "" {
		t.Fatal("expected archive architecture suffix")
	}
}

func TestPinnedReleaseRespectsOverrides(t *testing.T) {
	t.Setenv("NEST_MARIADB_VERSION", "11.8.2")
	t.Setenv("NEST_MARIADB_URL", "https://example.com/mariadb-11.8.2-arm64.zip")
	t.Setenv("NEST_MARIADB_SHA256", "abc123")

	release := PinnedRelease()
	if release.Version != "11.8.2" {
		t.Fatalf("expected overridden version, got %s", release.Version)
	}
	if release.ArchiveURL != "https://example.com/mariadb-11.8.2-arm64.zip" {
		t.Fatalf("expected overridden archive url, got %s", release.ArchiveURL)
	}
	if release.SHA256 != "abc123" {
		t.Fatalf("expected overridden sha256, got %s", release.SHA256)
	}
}
