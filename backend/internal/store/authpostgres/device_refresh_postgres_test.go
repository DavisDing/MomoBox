package authpostgres

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/momobox/backend/internal/auth"
)

// Opt-in only; the migration and all test rows live in a random isolated schema.
func TestPostgresRefreshBindsDeviceAndRejectsUnavailableTargets(t *testing.T) {
	dsn := strings.TrimSpace(os.Getenv("MOMO_TEST_DATABASE_URL"))
	if dsn == "" {
		t.Skip("MOMO_TEST_DATABASE_URL unset; real device-binding SQL validation not executed")
	}
	var entropy [10]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		t.Fatal(err)
	}
	schema := "momobox_auth_test_" + hex.EncodeToString(entropy[:])
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid explicit PostgreSQL test configuration")
	}
	if config.RuntimeParams == nil {
		config.RuntimeParams = map[string]string{}
	}
	config.RuntimeParams["search_path"] = schema
	db := stdlib.OpenDB(*config)
	defer db.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := db.ExecContext(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if _, err := db.ExecContext(cleanup, "DROP SCHEMA "+schema+" CASCADE"); err != nil {
			t.Error(err)
		}
	}()
	raw, err := os.ReadFile("../../../migrations/0001_initial_schema.sql")
	if err != nil {
		t.Fatal(err)
	}
	migration := strings.ReplaceAll(string(raw), "SET LOCAL search_path = public;", "SET LOCAL search_path = "+schema+";")
	migration = strings.ReplaceAll(migration, "CREATE EXTENSION IF NOT EXISTS pgcrypto;", "")
	if _, err := db.ExecContext(ctx, migration); err != nil {
		t.Fatal(err)
	}
	const user = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	const family = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	const phone = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
	for _, query := range []string{
		`INSERT INTO users(id,email,password_hash,nickname) VALUES('` + user + `','auth@example.test','fixture','test')`,
		`INSERT INTO families(id,name,created_by_user_id) VALUES('` + family + `','test','` + user + `')`,
		`INSERT INTO family_members(family_id,user_id,role) VALUES('` + family + `','` + user + `','owner')`,
		`UPDATE users SET current_family_id='` + family + `' WHERE id='` + user + `'`,
		`INSERT INTO sync_devices(id,family_id,user_id,device_name,platform) VALUES('` + phone + `','` + family + `','` + user + `','phone','other')`,
	} {
		if _, err := db.ExecContext(ctx, query); err != nil {
			t.Fatal(err)
		}
	}
	repository := NewRefreshTokenRepository(db)
	now := time.Now().UTC()
	initial := auth.RefreshTokenRecord{ID: "11111111-1111-4111-8111-111111111111", UserID: user, FamilyID: family, TokenHash: "unbound", CreatedAt: now, ExpiresAt: now.Add(time.Hour)}
	if err := repository.Create(ctx, initial); err != nil {
		t.Fatal(err)
	}
	for _, query := range []string{
		`INSERT INTO users(id,email,password_hash,nickname) VALUES('dddddddd-dddd-4ddd-8ddd-dddddddddddd','other@example.test','fixture','other')`,
		`INSERT INTO family_members(family_id,user_id,role) VALUES('` + family + `','dddddddd-dddd-4ddd-8ddd-dddddddddddd','member')`,
		`INSERT INTO families(id,name,created_by_user_id) VALUES('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','other family','` + user + `')`,
		`INSERT INTO family_members(family_id,user_id,role) VALUES('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','` + user + `','owner')`,
		`INSERT INTO sync_devices(id,family_id,user_id,device_name,platform) VALUES('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa','` + family + `','dddddddd-dddd-4ddd-8ddd-dddddddddddd','foreign user','other')`,
		`INSERT INTO sync_devices(id,family_id,user_id,device_name,platform) VALUES('aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','` + user + `','foreign family','other')`,
	} {
		if _, err := db.ExecContext(ctx, query); err != nil {
			t.Fatal(err)
		}
	}
	listed, err := NewDeviceRepository(db).ListUserDevices(ctx, user)
	if err != nil || len(listed) != 1 || listed[0].ID != phone {
		t.Fatalf("device listing escaped current owner/family: %+v %v", listed, err)
	}
	for _, unavailable := range []string{"aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa", "aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa", "ffffffff-ffff-4fff-8fff-ffffffffffff"} {
		target := initial
		target.ID = "66666666-6666-4666-8666-666666666666"
		target.TokenHash, target.DeviceID = "foreign-binding", unavailable
		if err := repository.Rotate(ctx, initial.TokenHash, target, now); err == nil {
			t.Fatalf("foreign/unknown target accepted: %s", unavailable)
		}
	}
	bound := initial
	bound.ID = "22222222-2222-4222-8222-222222222222"
	bound.TokenHash = "bound"
	bound.DeviceID = phone
	if err := repository.Rotate(ctx, initial.TokenHash, bound, now); err != nil {
		t.Fatal("bind registered device:", err)
	}
	stored, err := repository.FindByHash(ctx, bound.TokenHash)
	if err != nil || stored.DeviceID != phone || stored.FamilyID != family {
		t.Fatalf("binding not persisted: %+v %v", stored, err)
	}
	next := bound
	next.ID = "33333333-3333-4333-8333-333333333333"
	next.TokenHash = "rotated"
	if err := repository.Rotate(ctx, bound.TokenHash, next, now); err != nil {
		t.Fatal(err)
	}
	// A fresh unbound session must not bind a device that was revoked after
	// the earlier service-level lookup. Rollback leaves that session usable.
	initial.ID = "44444444-4444-4444-8444-444444444444"
	initial.TokenHash = "second-unbound"
	if err := repository.Create(ctx, initial); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `UPDATE sync_devices SET revoked_at=$1 WHERE id=$2`, now, phone); err != nil {
		t.Fatal(err)
	}
	bound.ID = "55555555-5555-4555-8555-555555555555"
	bound.TokenHash = "must-not-exist"
	if err := repository.Rotate(ctx, initial.TokenHash, bound, now); err == nil {
		t.Fatal("revoked device accepted")
	}
	stored, err = repository.FindByHash(ctx, initial.TokenHash)
	if err != nil || stored.RevokedAt != nil {
		t.Fatal("failed binding consumed the original session")
	}
	if _, err := repository.FindByHash(ctx, bound.TokenHash); err == nil {
		t.Fatal("failed binding persisted a replacement")
	}
}
