package family_test

import (
	"context"
	"errors"
	"testing"

	"github.com/momobox/backend/internal/family"
)

func TestFamilyTimeZoneDefaultsAndValidatesBeforePersistence(t *testing.T) {
	for _, test := range []struct {
		zone, want string
		valid      bool
	}{
		{"", "Asia/Shanghai", true},
		{"America/Los_Angeles", "America/Los_Angeles", true},
		{"not/a-zone", "", false},
		{"Local", "", false},
	} {
		service, repo, _, _ := newFamilyService(t)
		result, err := service.CreateFamily(context.Background(), "owner", family.CreateFamilyRequest{Name: "Home", TimeZone: test.zone})
		if test.valid {
			if err != nil || result.Family.TimeZone != test.want {
				t.Fatalf("zone %q: result=%+v err=%v", test.zone, result, err)
			}
		} else {
			var invalid *family.ServiceError
			if !errors.As(err, &invalid) || invalid.Code != family.CodeValidation || len(repo.values) != 0 {
				t.Fatalf("invalid zone persisted: result=%+v err=%v", result, err)
			}
		}
	}
}
