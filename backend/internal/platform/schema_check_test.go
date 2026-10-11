package platform

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestSchemaIdentityCheck(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"0001_initial.sql", "0002_more.sql"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("SELECT 1;\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	files, err := loadMigrationFiles(dir)
	if err != nil {
		t.Fatal(err)
	}
	one := MigrationRecord{Version: 1, Name: files[0].name, Checksum: files[0].checksum}
	two := MigrationRecord{Version: 2, Name: files[1].name, Checksum: files[1].checksum}
	badName := one
	badName.Name = "renamed.sql"
	badHash := one
	badHash.Checksum = "sha256:changed"
	for _, tc := range []struct {
		name    string
		records []MigrationRecord
		want    error
	}{
		{"ready", []MigrationRecord{one, two}, nil},
		{"unordered ready", []MigrationRecord{two, one}, nil},
		{"empty", nil, ErrMissingAppliedMigration},
		{"pending", []MigrationRecord{one}, ErrMissingAppliedMigration},
		{"unknown newer schema", []MigrationRecord{one, two, {Version: 3}}, ErrUnknownAppliedMigration},
		{"duplicate", []MigrationRecord{one, one, two}, ErrDuplicateMigrationVersion},
		{"renamed", []MigrationRecord{badName, two}, ErrMigrationNameMismatch},
		{"changed checksum", []MigrationRecord{badHash, two}, ErrMigrationChecksumMismatch},
	} {
		t.Run(tc.name, func(t *testing.T) {
			before := append([]MigrationRecord(nil), tc.records...)
			got := CheckMigrationSchema(context.Background(), dir, func(context.Context) ([]MigrationRecord, error) { return tc.records, nil })
			if !errors.Is(got, tc.want) {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
			for i, record := range before {
				if tc.records[i] != record {
					t.Fatal("checker changed migration identity")
				}
			}
		})
	}
	t.Run("read failure", func(t *testing.T) {
		failure := errors.New("query failed")
		if err := CheckMigrationSchema(context.Background(), dir, func(context.Context) ([]MigrationRecord, error) { return nil, failure }); !errors.Is(err, failure) {
			t.Fatalf("lost read error: %v", err)
		}
	})
	t.Run("cancel before read", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		err := CheckMigrationSchema(ctx, dir, func(context.Context) ([]MigrationRecord, error) {
			t.Fatal("read after cancellation")
			return nil, nil
		})
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	})
	t.Run("cancel during read", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		err := CheckMigrationSchema(ctx, dir, func(context.Context) ([]MigrationRecord, error) {
			cancel()
			return []MigrationRecord{one, two}, nil
		})
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	})
	t.Run("no files", func(t *testing.T) {
		err := CheckMigrationSchema(context.Background(), t.TempDir(), func(context.Context) ([]MigrationRecord, error) {
			t.Fatal("read without image manifest")
			return nil, nil
		})
		if !errors.Is(err, ErrNoMigrations) {
			t.Fatal(err)
		}
	})
	t.Run("nil reader", func(t *testing.T) {
		if CheckMigrationSchema(context.Background(), dir, nil) == nil {
			t.Fatal("accepted missing reader")
		}
	})
}

func TestSchemaCheckKeepsPinnedLegacyCompatibilityReadOnly(t *testing.T) {
	dir := "../../migrations"
	files, err := loadMigrationFiles(dir)
	if err != nil {
		t.Fatal(err)
	}
	var records []MigrationRecord
	for _, file := range files {
		hash := file.checksum
		if file.version == 1 {
			hash = file.legacyChecksum
		}
		records = append(records, MigrationRecord{Version: file.version, Name: file.name, Checksum: hash})
	}
	err = CheckMigrationSchema(context.Background(), dir, func(context.Context) ([]MigrationRecord, error) { return records, nil })
	if err != nil {
		t.Fatal(err)
	}
	if records[0].Checksum != files[0].legacyChecksum {
		t.Fatal("legacy checksum changed")
	}
	// A modified file must not exploit its old textual marker as approval.
	copyDir := t.TempDir()
	for _, file := range files {
		contents := file.contents
		if file.version == 1 {
			contents += "\n-- edited\n"
		}
		if err := os.WriteFile(filepath.Join(copyDir, file.name), []byte(contents), 0600); err != nil {
			t.Fatal(err)
		}
	}
	err = CheckMigrationSchema(context.Background(), copyDir, func(context.Context) ([]MigrationRecord, error) { return records, nil })
	if !errors.Is(err, ErrMigrationChecksumMismatch) {
		t.Fatalf("modified legacy file accepted: %v", err)
	}
}
