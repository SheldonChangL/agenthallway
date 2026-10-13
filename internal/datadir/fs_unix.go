//go:build !windows

package datadir

import (
	"fmt"
	"os"
	"syscall"
)

// syncDirectory makes a name just linked into, or removed from, a directory
// survive a power loss. The same as identity's: without it the file's content
// is durable but the directory entry that names it need not be.
func syncDirectory(directory string) error {
	// #nosec G304 -- the directory is opened only to fsync it; nothing is read
	// through this handle.
	handle, err := os.Open(directory)
	if err != nil {
		return fmt.Errorf("open %s to flush it: %w", directory, err)
	}
	defer func() { _ = handle.Close() }()
	if err := handle.Sync(); err != nil {
		return fmt.Errorf("flush %s: %w", directory, err)
	}
	return nil
}

// sameFilesystem reports whether two existing paths are on one device, which
// a hard link between them needs.
func sameFilesystem(a, b string) (bool, error) {
	first, err := os.Stat(a)
	if err != nil {
		return false, err
	}
	second, err := os.Stat(b)
	if err != nil {
		return false, err
	}
	firstSys, ok := first.Sys().(*syscall.Stat_t)
	if !ok {
		return true, nil // the link itself is the check, and fails cleanly
	}
	secondSys, ok := second.Sys().(*syscall.Stat_t)
	if !ok {
		return true, nil
	}
	return firstSys.Dev == secondSys.Dev, nil
}
