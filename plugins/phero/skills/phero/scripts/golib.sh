#!/usr/bin/env bash
# golib.sh MODULE [VERSION]
#
# Puts the exact source of a Go module on disk and prints a map of it (docs,
# examples, packages) plus the state of the local toolchain, so the agent reads
# the real library instead of guessing from memory.
#
# VERSION: the argument, else the version the current Go module requires
# (go list -m), else the latest release.
#
# Source, first that works:
#   1. go mod download  -> Go module cache (version-exact, read-only, offline once fetched)
#   2. curl + unzip     -> the same zip from the module proxy, when Go is not installed
#   3. git clone        -> shallow clone of the tag
#   4. URLs             -> GitHub links to read with a web fetch tool
set -uo pipefail

mod="${1:?usage: golib.sh MODULE [VERSION]}"
ver="${2:-}"
pinned="no"
proxy="${GOPROXY:-https://proxy.golang.org}"; proxy="${proxy%%,*}"
[[ "$proxy" == direct || "$proxy" == off ]] && proxy="https://proxy.golang.org"
repo=$(sed -E 's#^(github\.com/[^/]+/[^/]+).*#\1#' <<<"$mod")
cache="${XDG_CACHE_HOME:-$HOME/.cache}/golib-src"
have() { command -v "$1" >/dev/null 2>&1; }
note() { echo "golib: $*" >&2; }

if [[ -z "$ver" ]] && have go; then
  if v=$(go list -m -f '{{.Version}}' "$mod" 2>/dev/null) && [[ -n "$v" ]]; then
    ver="$v"; pinned="yes (from go.mod)"
  fi
fi
ver="${ver:-latest}"

dir=""; how=""; latest="?"; err=""

# 1. Go module cache. Run outside any module so the user's go.mod is never touched.
if have go; then
  # Cache-only probe first, so "fetching" is printed only when we really download.
  cached=$(cd "${TMPDIR:-/tmp}" && GO111MODULE=on GOPROXY=off GOFLAGS=-mod=mod go mod download -json "$mod@$ver" 2>/dev/null) || cached=""
  if [[ "$cached" != *'"Dir"'* || "$cached" == *'"Error"'* ]]; then
    if [[ "$ver" == latest ]]; then note "resolving the latest $mod (downloads once per new release)..."
    else note "fetching $mod@$ver into the Go module cache (first time only)..."; fi
    out=$(cd "${TMPDIR:-/tmp}" && GO111MODULE=on GOFLAGS=-mod=mod go mod download -json "$mod@$ver" 2>&1)
  else
    out="$cached"
  fi
  dir=$(sed -n 's/^[[:space:]]*"Dir": "\(.*\)",\{0,1\}$/\1/p' <<<"$out")
  if [[ -n "$dir" && -d "$dir" ]]; then
    ver=$(sed -n 's/^[[:space:]]*"Version": "\(.*\)",\{0,1\}$/\1/p' <<<"$out")
    how="go module cache"
    latest=$(cd "${TMPDIR:-/tmp}" && GO111MODULE=on go list -m -f '{{.Version}}' "$mod@latest" 2>/dev/null || echo "?")
  else
    dir=""; err="go mod download failed: $(sed -n 's/^[[:space:]]*"Error": "\(.*\)",\{0,1\}$/\1/p' <<<"$out" | head -1)$(grep -v '^[[:space:]]*[{}"]' <<<"$out" | head -3)"
    note "$err"
  fi
fi

# 2. Module proxy zip (same bytes as the module cache), for machines without Go.
if [[ -z "$dir" ]] && have curl && have unzip; then
  if [[ "$ver" == latest ]]; then
    ver=$(curl -fsSL "$proxy/$mod/@latest" 2>/dev/null | sed -n 's/.*"Version":"\([^"]*\)".*/\1/p')
  fi
  if [[ -n "$ver" && "$ver" != latest ]]; then
    latest="$ver"
    d="$cache/zip/$mod@$ver"
    if [[ ! -d "$d" ]]; then
      note "fetching $mod@$ver from $proxy (first run only)..."
      tmp=$(mktemp -d)
      if curl -fsSL -o "$tmp/m.zip" "$proxy/$mod/@v/$ver.zip" && unzip -q "$tmp/m.zip" -d "$tmp/x"; then
        mkdir -p "$(dirname "$d")" && mv "$tmp/x/$mod@$ver" "$d"
      fi
      rm -rf "$tmp"
    fi
    [[ -d "$d" ]] && dir="$d" && how="module proxy zip (Go not installed)"
  fi
fi

# 3. Shallow git clone of the tag.
if [[ -z "$dir" ]] && have git; then
  if [[ "$ver" == latest || -z "$ver" ]]; then
    ver=$(git ls-remote --tags --refs "https://$repo" 2>/dev/null | sed 's#.*refs/tags/##' \
          | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
  fi
  if [[ -n "$ver" ]]; then
    latest="$ver"
    d="$cache/git/$(tr / _ <<<"$repo")@$ver"
    [[ -d "$d" ]] || { note "cloning $repo@$ver (first run only)..."; git clone -q --depth 1 --branch "$ver" "https://$repo" "$d" 2>/dev/null; }
    [[ -d "$d" ]] && dir="$d" && how="git clone"
  fi
fi

echo "## Environment"
if have go; then
  gov=$(go env GOVERSION 2>/dev/null); gov="${gov#go}"
  echo "  go:          $gov (GOTOOLCHAIN=$(go env GOTOOLCHAIN 2>/dev/null))"
else
  echo "  go:          NOT INSTALLED. The user needs Go to build the app: https://go.dev/dl/"
fi
for t in git docker nats-server; do
  if have "$t"; then echo "  $t: found"; else echo "  $t: not found"; fi
done
need=""
[[ -n "$dir" && -f "$dir/go.mod" ]] && need=$(sed -n 's/^go \([0-9.]*\).*/\1/p' "$dir/go.mod")
if [[ -n "$need" ]]; then
  echo "  module needs go >= $need"
  if have go && [[ "$(printf '%s\n%s\n' "$need" "$gov" | sort -V | head -1)" != "$need" ]]; then
    if [[ "$(go env GOTOOLCHAIN)" == local* ]]; then
      echo "  WARNING: local go $gov is older and GOTOOLCHAIN=local, so builds will fail. Upgrade Go or set GOTOOLCHAIN=auto."
    else
      echo "  NOTE: local go $gov is older. 'go get' will download go$need automatically (one-time, ~70MB)."
    fi
  fi
fi
echo

if [[ -z "$dir" ]]; then
  t="${ver:-latest}"; t="${t/latest/<latest tag>}"
  echo "## Source: NOT AVAILABLE LOCALLY"
  [[ -n "$err" ]] && echo "  last error: $err"
  echo "  Could not fetch the module (no network, a blocked proxy, or no go/curl/git)."
  echo "  If a proxy is blocked, try GOPROXY=direct, or GOPRIVATE for a private fork."
  echo "  Read the library with a web fetch tool instead:"
  echo "    https://pkg.go.dev/$mod                     (API docs, latest)"
  echo "    https://github.com/${repo#github.com/}/tree/$t/examples"
  echo "    https://raw.githubusercontent.com/${repo#github.com/}/$t/README.md"
  echo "    https://github.com/${repo#github.com/}/releases   (find the latest tag)"
  exit 2
fi

echo "## Source"
echo "  module:  $mod"
echo "  version: $ver   (pinned by project: $pinned; latest release: $latest)"
echo "  dir:     $dir"
echo "  via:     $how. Read-only; never edit files here."
echo
echo "## Docs"
for f in README.md docs/*.md web/*.md; do
  for g in "$dir"/$f; do [[ -f "$g" ]] && echo "  $g"; done
done
find "$dir/web" -name '*.html' 2>/dev/null | sort | sed 's/^/  /'
echo
echo "## Examples (one dir per runnable program; read main.go + README.md)"
if [[ -d "$dir/examples" ]]; then
  find "$dir/examples" -name main.go -not -path '*/internal/*' | sort \
    | sed "s#^$dir/examples/##; s#/main.go\$##; s/^/  /"
fi
echo
echo "## Packages"
(cd "$dir" && find . -name '*.go' -not -name '*_test.go' \
   -not -path './examples/*' -not -path '*/internal/*' -not -path './e2e/*' \
   -exec dirname {} \; | sort -u | sed 's#^\./##; s#^\.$#. (root)#; s/^/  /')
echo
echo "## Exact signatures"
if have go; then
  echo "  Works now, no project needed:   cd $dir && go doc ./<pkg> <Symbol>"
  echo "  In the user's module after 'go get $mod@$ver':   go doc $mod/<pkg>.<Symbol>"
else
  echo "  Go is not installed: grep the package sources under $dir"
fi
