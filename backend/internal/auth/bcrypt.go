package auth

import "golang.org/x/crypto/bcrypt"

const BcryptCost = 12

// BcryptPasswordHasher is the production adapter required by the NAS
// security contract. The service still depends on PasswordHasher so tests and
// deployments can provide an explicit implementation without coupling the
// domain service to a password-storage package.
type BcryptPasswordHasher struct{}

func (BcryptPasswordHasher) Hash(password string) (string, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), BcryptCost)
	return string(hash), err
}

func (BcryptPasswordHasher) Compare(encodedHash, password string) error {
	return bcrypt.CompareHashAndPassword([]byte(encodedHash), []byte(password))
}
