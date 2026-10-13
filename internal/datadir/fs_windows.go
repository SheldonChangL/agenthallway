//go:build windows

package datadir

// syncDirectory is a no-op on Windows, as it is in identity: a directory
// cannot be opened for flushing there, and NTFS journals the metadata.
func syncDirectory(string) error { return nil }

// sameFilesystem answers yes on Windows. The hard link is the check: it fails
// across volumes, before anything is removed.
func sameFilesystem(string, string) (bool, error) { return true, nil }
