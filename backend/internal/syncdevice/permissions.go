package syncdevice

import "errors"

func authorizeDevice(actor Actor, device Device) error {
	if device.FamilyID != actor.FamilyID {
		// Treat an out-of-family resource as not found to avoid cross-family
		// existence leaks. Repository implementations should already scope it.
		return ErrNotFound
	}
	if actor.Role == RoleOwner || actor.Role == RoleAdmin {
		return nil
	}
	if device.UserID != actor.UserID {
		return ErrForbidden
	}
	return nil
}

func authorizeOwnCurrentDevice(actor Actor, device Device) error {
	if err := authorizeDevice(actor, device); err != nil {
		return err
	}
	if device.UserID != actor.UserID || device.ID != actor.DeviceID {
		return ErrForbidden
	}
	return nil
}

func translateRepositoryError(err error) error {
	if err == nil {
		return nil
	}
	// Repository implementations may wrap the shared sentinels. Keep the
	// public service errors stable without exposing SQL/storage details.
	for _, known := range []error{ErrNotFound, ErrConflict, ErrCursorRegression, ErrRevoked} {
		if errors.Is(err, known) {
			return known
		}
	}
	return err
}
