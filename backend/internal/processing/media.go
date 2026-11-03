// Package processing implements authenticated household media processing.
// Images live in PostgreSQL so ordinary database backups include their bytes.
package processing

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	_ "image/png"
	"io"
	"os/exec"
	"strings"
	"time"
)

const MaxImageBytes = 8 << 20

var ErrInvalid = errors.New("invalid processing request")
var ErrConflict = errors.New("media identity conflicts with existing content or was deleted")
var ErrBusy = errors.New("processing in progress; retry later")
var ErrOutcomeUnknown = errors.New("AI result is unknown; submit a new explicit request only after review")
var ErrUnavailable = errors.New("backend processor unavailable")

type Asset struct {
	ID         string     `json:"id"`
	EntityType string     `json:"entity_type"`
	EntityID   string     `json:"entity_id"`
	MediaType  string     `json:"media_type"`
	SHA256     string     `json:"sha256"`
	Content    []byte     `json:"content,omitempty"`
	MimeType   string     `json:"mime_type"`
	SizeBytes  int        `json:"size_bytes"`
	OCRStatus  string     `json:"ocr_status"`
	OCRText    string     `json:"ocr_text"`
	OCRError   *string    `json:"ocr_error"`
	CreatedAt  time.Time  `json:"created_at"`
	DeletedAt  *time.Time `json:"deleted_at"`
}
type Upload struct {
	ID         string `json:"id"`
	EntityType string `json:"entity_type"`
	EntityID   string `json:"entity_id"`
	MediaType  string `json:"media_type"`
	Content    []byte `json:"content"`
	OCRText    string `json:"ocr_text,omitempty"`
}
type OCRFunc func(context.Context, []byte) (string, error)
type Service struct {
	DB         *sql.DB
	OCR        OCRFunc
	AI         AIConfig
	slots      chan struct{}
	imageSlots chan struct{}
}

func New(db *sql.DB, ai AIConfig) *Service {
	return &Service{DB: db, OCR: Tesseract, AI: ai, slots: make(chan struct{}, 2), imageSlots: make(chan struct{}, 1)}
}
func UUID(v string) bool {
	if len(v) != 36 || v[8] != '-' || v[13] != '-' || v[18] != '-' || v[23] != '-' {
		return false
	}
	_, err := hex.DecodeString(strings.ReplaceAll(v, "-", ""))
	return err == nil
}
func validEntity(kind, id string) bool {
	return (kind == "product" || kind == "intake_draft") && UUID(id)
}
func NormalizeImage(raw []byte) ([]byte, error) {
	if len(raw) == 0 || len(raw) > MaxImageBytes {
		return nil, ErrInvalid
	}
	config, _, err := image.DecodeConfig(bytes.NewReader(raw))
	if err != nil || config.Width < 1 || config.Height < 1 || config.Width > 12000 || config.Height > 12000 || int64(config.Width)*int64(config.Height) > 24000000 {
		return nil, ErrInvalid
	}
	img, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, ErrInvalid
	}
	// Decode and re-encode on the server: EXIF/location and embedded metadata
	// are never retained or forwarded to the AI provider.
	img = orientImage(img, jpegOrientation(raw))
	var out bytes.Buffer
	if err = jpeg.Encode(&out, img, &jpeg.Options{Quality: 82}); err != nil {
		return nil, err
	}
	if out.Len() > MaxImageBytes {
		return nil, ErrInvalid
	}
	return out.Bytes(), nil
}

const assetColumns = `id::text,entity_type,entity_id::text,media_type,source_sha256,content,mime_type,size_bytes,ocr_status,ocr_text,ocr_error,created_at,deleted_at`

type scanner interface{ Scan(...any) error }

func scanAsset(row scanner) (Asset, error) {
	var a Asset
	err := row.Scan(&a.ID, &a.EntityType, &a.EntityID, &a.MediaType, &a.SHA256, &a.Content, &a.MimeType, &a.SizeBytes, &a.OCRStatus, &a.OCRText, &a.OCRError, &a.CreatedAt, &a.DeletedAt)
	return a, err
}
func (s *Service) Get(ctx context.Context, family, id string) (Asset, error) {
	if !UUID(id) {
		return Asset{}, ErrInvalid
	}
	return scanAsset(s.DB.QueryRowContext(ctx, `SELECT `+assetColumns+` FROM media_assets WHERE family_id=$1::uuid AND id=$2::uuid`, family, id))
}
func (s *Service) Upload(ctx context.Context, family, user string, u Upload) (Asset, error) {
	if len(u.OCRText) > 100000 || !UUID(u.ID) || !validEntity(u.EntityType, u.EntityID) || (u.MediaType != "product_image" && u.MediaType != "instruction_image") {
		return Asset{}, ErrInvalid
	}
	sum := sha256.Sum256(u.Content)
	hash := hex.EncodeToString(sum[:])
	existing, err := s.Get(ctx, family, u.ID)
	if err == nil {
		if existing.DeletedAt != nil || existing.SHA256 != hash || existing.MediaType != u.MediaType || existing.EntityType != u.EntityType || existing.EntityID != u.EntityID {
			return Asset{}, ErrConflict
		}
		return existing, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return Asset{}, err
	}
	select {
	case s.imageSlots <- struct{}{}:
		defer func() { <-s.imageSlots }()
	default:
		return Asset{}, ErrBusy
	}
	normalized, err := NormalizeImage(u.Content)
	if err != nil {
		return Asset{}, err
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return Asset{}, err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,1011))`, family+":"+u.ID); err != nil {
		return Asset{}, err
	}
	if u.EntityType == "product" {
		var productID string
		err := tx.QueryRowContext(ctx, `SELECT id::text FROM products WHERE id=$1::uuid AND family_id=$2::uuid AND deleted_at IS NULL FOR KEY SHARE`, u.EntityID, family).Scan(&productID)
		if err != nil {
			return Asset{}, err
		}
	}
	var deleted bool
	if err = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM media_tombstones WHERE family_id=$1::uuid AND id=$2::uuid)`, family, u.ID).Scan(&deleted); err != nil {
		return Asset{}, err
	}
	if deleted {
		return Asset{}, ErrConflict
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO media_assets(family_id,id,entity_type,entity_id,media_type,source_sha256,content,size_bytes,created_by,ocr_text,ocr_status,ocr_origin) VALUES($1::uuid,$2::uuid,$3,$4::uuid,$5,$6,$7,$8,$9::uuid,$10,CASE WHEN $10='' THEN 'pending' ELSE 'complete' END,CASE WHEN $10='' THEN 'backend' ELSE 'local_migration' END) ON CONFLICT(family_id,id) DO NOTHING`, family, u.ID, u.EntityType, u.EntityID, u.MediaType, hash, normalized, len(normalized), user, strings.TrimSpace(u.OCRText))
	if err != nil {
		return Asset{}, err
	}
	if err = tx.Commit(); err != nil {
		return Asset{}, err
	}
	a, err := s.Get(ctx, family, u.ID)
	if err == nil && (a.DeletedAt != nil || a.SHA256 != hash || a.EntityType != u.EntityType || a.EntityID != u.EntityID || a.MediaType != u.MediaType) {
		return Asset{}, ErrConflict
	}
	return a, err
}
func (s *Service) List(ctx context.Context, family, kind, id, after string) ([]Asset, error) {
	if !(validEntity(kind, id) || (kind == "product" && id == "")) || (after != "" && !UUID(after)) {
		return nil, ErrInvalid
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT `+strings.Replace(assetColumns, "source_sha256,content,", "source_sha256,NULL::bytea,", 1)+` FROM media_assets WHERE family_id=$1::uuid AND entity_type=$2 AND ($3='' OR entity_id=NULLIF($3,'')::uuid) AND ($4='' OR id>NULLIF($4,'')::uuid) ORDER BY id LIMIT 50`, family, kind, id, after)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]Asset, 0)
	for rows.Next() {
		a, e := scanAsset(rows)
		if e != nil {
			return nil, e
		}
		a.Content = nil
		result = append(result, a)
	}
	return result, rows.Err()
}
func (s *Service) Delete(ctx context.Context, family, id string) error {
	if !UUID(id) {
		return ErrInvalid
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,1011))`, family+":"+id); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO media_tombstones(family_id,id) VALUES($1::uuid,$2::uuid) ON CONFLICT DO NOTHING`, family, id); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `UPDATE media_assets SET content=NULL,ocr_text='',ocr_error=NULL,deleted_at=COALESCE(deleted_at,CURRENT_TIMESTAMP),updated_at=CURRENT_TIMESTAMP WHERE family_id=$1::uuid AND id=$2::uuid`, family, id); err != nil {
		return err
	}
	return tx.Commit()
}
func (s *Service) Reassign(ctx context.Context, family, id, product string) error {
	if !UUID(id) || !UUID(product) {
		return ErrInvalid
	}
	result, err := s.DB.ExecContext(ctx, `UPDATE media_assets SET entity_type='product',entity_id=$3::uuid,updated_at=CURRENT_TIMESTAMP WHERE family_id=$1::uuid AND id=$2::uuid AND deleted_at IS NULL AND EXISTS(SELECT 1 FROM products p WHERE p.id=$3::uuid AND p.family_id=$1::uuid AND p.deleted_at IS NULL) AND (entity_type='intake_draft' OR (entity_type='product' AND entity_id=$3::uuid))`, family, id, product)
	if err != nil {
		return err
	}
	n, err := result.RowsAffected()
	if err == nil && n != 1 {
		return ErrConflict
	}
	return err
}
func (s *Service) RunOCR(ctx context.Context, family, id string) (Asset, error) {
	a, err := s.Get(ctx, family, id)
	if err != nil {
		return Asset{}, err
	}
	if a.DeletedAt != nil {
		return Asset{}, sql.ErrNoRows
	}
	if a.OCRStatus == "complete" {
		return a, nil
	}
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
	default:
		return Asset{}, ErrBusy
	}
	// A crashed request may leave processing behind; the bounded lease expires.
	result, err := s.DB.ExecContext(ctx, `UPDATE media_assets SET ocr_status='processing',ocr_error=NULL,processing_started_at=CURRENT_TIMESTAMP WHERE family_id=$1::uuid AND id=$2::uuid AND deleted_at IS NULL AND (ocr_status IN ('pending','failed') OR processing_started_at<CURRENT_TIMESTAMP-INTERVAL '2 minutes')`, family, id)
	if err != nil {
		return Asset{}, err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return Asset{}, err
	}
	if n != 1 {
		return Asset{}, ErrBusy
	}
	work, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	text, ocrErr := s.OCR(work, a.Content)
	status := "complete"
	var message *string
	if ocrErr != nil {
		status = "failed"
		m := "OCR failed; retry or enter text manually"
		message = &m
	}
	// Persist failure even after the caller disconnects. Never revive a tombstone.
	persist, stop := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
	defer stop()
	_, err = s.DB.ExecContext(persist, `UPDATE media_assets SET ocr_status=$3,ocr_text=$4,ocr_error=$5,ocr_origin='backend',updated_at=CURRENT_TIMESTAMP WHERE family_id=$1::uuid AND id=$2::uuid AND deleted_at IS NULL`, family, id, status, text, message)
	if err != nil {
		return Asset{}, err
	}
	a, err = s.Get(persist, family, id)
	if err == nil && a.DeletedAt != nil {
		return Asset{}, sql.ErrNoRows
	}
	return a, err
}

// limitedOutput bounds subprocess output without retaining stderr (which may
// contain file paths or OCR source material).
type limitedOutput struct {
	bytes.Buffer
	max int
}

func (b *limitedOutput) Write(p []byte) (int, error) {
	if b.Len()+len(p) > b.max {
		return 0, fmt.Errorf("output too large")
	}
	return b.Buffer.Write(p)
}
func Tesseract(ctx context.Context, content []byte) (string, error) {
	cmd := exec.CommandContext(ctx, "tesseract", "stdin", "stdout", "-l", "chi_sim+eng")
	cmd.Stdin = bytes.NewReader(content)
	cmd.Stderr = io.Discard
	out := &limitedOutput{max: 100000}
	cmd.Stdout = out
	if err := cmd.Run(); err != nil {
		return "", ErrUnavailable
	}
	return strings.TrimSpace(out.String()), nil
}
