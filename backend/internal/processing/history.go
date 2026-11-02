package processing

import (
	"context"
	"strings"
	"time"
	"unicode"
)

type HistoryRecord struct {
	Cursor      int64     `json:"cursor"`
	ID          string    `json:"id"`
	ProductID   string    `json:"product_id"`
	BatchID     string    `json:"batch_id"`
	OperationID *string   `json:"operation_id"`
	Type        string    `json:"type"`
	Quantity    int       `json:"quantity"`
	Note        *string   `json:"note"`
	CreatedAt   time.Time `json:"created_at"`
}
type HistoryPage struct {
	Records []HistoryRecord `json:"records"`
	Next    int64           `json:"next_cursor"`
	Until   int64           `json:"until"`
	HasMore bool            `json:"has_more"`
}

func (s *Service) History(ctx context.Context, family string, after, until int64, limit int) (HistoryPage, error) {
	out := HistoryPage{Records: make([]HistoryRecord, 0), Next: after, Until: until}
	if after < 0 || until < 0 || (until != 0 && after > until) || limit < 1 || limit > 500 {
		return out, ErrInvalid
	}
	if until == 0 {
		if err := s.DB.QueryRowContext(ctx, `SELECT COALESCE(MAX(history_cursor),0) FROM consumption_records WHERE family_id=$1::uuid`, family).Scan(&out.Until); err != nil {
			return out, err
		}
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT history_cursor,id::text,product_id::text,batch_id::text,operation_id::text,record_type,quantity_change,reason,COALESCE(client_occurred_at,created_at) FROM consumption_records WHERE family_id=$1::uuid AND history_cursor>$2 AND history_cursor<=$3 ORDER BY history_cursor LIMIT $4`, family, after, out.Until, limit+1)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		var r HistoryRecord
		if err := rows.Scan(&r.Cursor, &r.ID, &r.ProductID, &r.BatchID, &r.OperationID, &r.Type, &r.Quantity, &r.Note, &r.CreatedAt); err != nil {
			return out, err
		}
		if len(out.Records) == limit {
			out.HasMore = true
			break
		}
		out.Records = append(out.Records, r)
		out.Next = r.Cursor
	}
	if !out.HasMore {
		out.Next = out.Until
	}
	return out, rows.Err()
}

type ManualSource struct {
	AssetID   string    `json:"asset_id"`
	Label     string    `json:"label"`
	Snippet   string    `json:"snippet"`
	CreatedAt time.Time `json:"created_at"`
}

func (s *Service) SearchManual(ctx context.Context, family, product, query string) ([]ManualSource, error) {
	if !UUID(product) || len(query) == 0 || len(query) > 1500 {
		return nil, ErrInvalid
	}
	tokens := manualTokens(query)
	rows, err := s.DB.QueryContext(ctx, `SELECT m.id::text,m.media_type,substring(m.ocr_text FROM GREATEST(1,h.first_match-120) FOR 700),m.created_at
 FROM media_assets m
 CROSS JOIN LATERAL (
   SELECT MIN(strpos(lower(m.ocr_text),token))::integer AS first_match,COUNT(*) AS score
   FROM unnest($3::text[]) AS token WHERE strpos(lower(m.ocr_text),token)>0
 ) h
 WHERE m.family_id=$1::uuid AND m.entity_type='product' AND m.entity_id=$2::uuid
   AND m.deleted_at IS NULL AND m.ocr_status='complete' AND h.score>0
 ORDER BY h.score DESC,m.created_at DESC LIMIT 5`, family, product, tokens)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]ManualSource, 0)
	for rows.Next() {
		var v ManualSource
		if err := rows.Scan(&v.AssetID, &v.Label, &v.Snippet, &v.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func manualTokens(query string) []string {
	query = strings.ToLower(strings.TrimSpace(query))
	tokens := []string{query}
	seen := map[string]bool{query: true}
	add := func(s string) {
		if len(tokens) < 48 && s != "" && !seen[s] {
			seen[s] = true
			tokens = append(tokens, s)
		}
	}
	words := strings.FieldsFunc(query, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
	for _, word := range words {
		add(word)
		runes := []rune(word)
		for i := 0; i+1 < len(runes); i++ {
			if unicode.Is(unicode.Han, runes[i]) && unicode.Is(unicode.Han, runes[i+1]) {
				add(string(runes[i : i+2]))
			}
		}
	}
	return tokens
}
