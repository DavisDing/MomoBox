package family

// Authorize centralizes the role matrix so HTTP and future application
// adapters do not duplicate authorization rules.
type Permission string

const (
	PermissionView         Permission = "view"
	PermissionCreateInvite Permission = "create_invite"
	PermissionRemoveMember Permission = "remove_member"
	PermissionRenameFamily Permission = "rename_family"
)

func Authorize(role Role, permission Permission) bool {
	switch permission {
	case PermissionView:
		return CanViewFamily(role)
	case PermissionCreateInvite:
		return CanCreateInvite(role)
	case PermissionRemoveMember:
		return CanRemoveMember(role)
	case PermissionRenameFamily:
		return CanRenameFamily(role)
	default:
		return false
	}
}
