#!/bin/sh
# Install gosec $GOSEC_VERSION built against golang.org/x/tools
# $GOSEC_XTOOLS_VERSION.
#
# gosec v2.29.0 pins x/tools v0.49.0, whose importer reads export data up to
# version 4. go1.27.2 writes version 5, so the stock build reports every
# package as "could not import ... export data version 5 is greater than
# maximum supported version 4" and exits 1 with zero findings: a red job that
# scanned nothing. x/tools v0.52.0 is the first release that reads version 5;
# building the same gosec against it scans normally.
#
# Go back to a plain `go install .../cmd/gosec@$GOSEC_VERSION` once a gosec
# release itself requires x/tools v0.52.0 or later.
set -eu
: "${GOSEC_VERSION:?set GOSEC_VERSION}" "${GOSEC_XTOOLS_VERSION:?set GOSEC_XTOOLS_VERSION}"

build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
cd "$build"
go mod init gosec-build >/dev/null 2>&1
go get "github.com/securego/gosec/v2/cmd/gosec@$GOSEC_VERSION" "golang.org/x/tools@$GOSEC_XTOOLS_VERSION"
go install github.com/securego/gosec/v2/cmd/gosec
bin=$(go env GOBIN)
[ -n "$bin" ] || bin="$(go env GOPATH)/bin"
go version -m "$bin/gosec" | grep -E 'securego/gosec/v2|golang.org/x/tools'
