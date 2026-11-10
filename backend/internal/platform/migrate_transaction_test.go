package platform

import (
	"strings"
	"testing"
)

func TestStripOuterTransactionHandlesCommentsAndBlankLines(t *testing.T) {
	for _, contents := range []string{
		"BEGIN;\nSELECT 1;\nCOMMIT;\n",
		"-- heading\n\nBEGIN;\nSELECT 1;\n\n-- runner records the checksum\n\nCOMMIT;\n",
		"/* heading */\n\nBEGIN;\nSELECT 1;\n/* footer */\n\nCOMMIT;\n-- trailing comment",
	} {
		if got := stripOuterTransaction(contents); got != "SELECT 1;" {
			t.Fatalf("outer transaction was not removed: %q", got)
		}
	}
	files, err := loadMigrationFiles("../../migrations")
	if err != nil {
		t.Fatal(err)
	}
	for _, file := range files {
		stripped := stripOuterTransaction(file.contents)
		if leadingBeginPattern.MatchString(stripped) || trailingCommitPattern.MatchString(stripped) || strings.HasSuffix(stripped, "COMMIT;") {
			t.Fatalf("migration %s retains an outer transaction", file.name)
		}
	}
}
