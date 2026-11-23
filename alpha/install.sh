#!/bin/sh
# Installs the Veritwin Token Swap CLI on macOS or Linux: a standalone build that brings its own
# Node.js, as `veritwin` in a bin folder.
#
#   alpha:  curl -fsSL https://veritwin.github.io/token-swap-cli/alpha/install.sh | sh
#   prod:   curl -fsSL https://veritwin.github.io/token-swap-cli/install.sh | sh
#   dev:    sh apps/cli/release/install.sh --dev        (from a checkout of Veritwin/token-swap)
#
# Each copy that ships has its release type built in (the RELEASE_TYPE line below, filled in by
# the release build): the copy at an install address, and the one inside every build, which
# `veritwin update` runs. Only the source copy in the repo has none; it installs dev releases,
# with --dev.
#
# Options (each also from the environment):
#   --version <v>    VERITWIN_VERSION   install that version instead of the newest (older too)
#   --archive <f>                       install a local build archive
#   --home <dir>     VERITWIN_HOME      default ~/.veritwin
#   --bin-dir <dir>  VERITWIN_BIN_DIR   default ~/.local/bin
#   --dev                               the source copy only: install a dev release
# Hosts (tests point them at local stubs): VERITWIN_NPM_REGISTRY, VERITWIN_RELEASES_URL.
#
# Steps: the newest version of the type (npm's dist-tags; dev: gh), the archive and SHA256SUMS
# from its release, the checksum, a new version folder, the `veritwin` wrapper, the old version
# folders removed. Nothing changes until the archive is downloaded and checked.
set -eu

RELEASE_TYPE="alpha"

PAGES="https://veritwin.github.io/token-swap-cli"
DEV_REPO="Veritwin/token-swap"
NAME="Veritwin Token Swap CLI"

say() { printf '%s\n' "$*"; }
die() {
  printf 'veritwin install: %s\n' "$*" >&2
  exit 1
}
usage() {
  cat <<'EOF_USAGE'
Installs the Veritwin Token Swap CLI (macOS, Linux).

Options (each also from the environment):
  --version <v>    VERITWIN_VERSION   install that version instead of the newest (older too)
  --archive <f>                       install a local build archive
  --home <dir>     VERITWIN_HOME      default ~/.veritwin
  --bin-dir <dir>  VERITWIN_BIN_DIR   default ~/.local/bin
  --dev                               the source copy in the repo only: install a dev release
EOF_USAGE
}

num='(0|[1-9][0-9]*)'

# The type of a version (prod, alpha or dev), or nothing when it isn't one.
version_type() {
  case "$1" in
    *[!0-9a-z.-]* | "") return 0 ;;
  esac
  if printf '%s\n' "$1" | grep -Eq "^$num\.$num\.$num\$"; then
    echo prod
  elif printf '%s\n' "$1" | grep -Eq "^$num\.$num\.$num-alpha\.$num\$"; then
    echo alpha
  elif printf '%s\n' "$1" | grep -Eq "^$num\.$num\.$num-dev\.$num\$"; then
    echo dev
  fi
}

an() {
  if [ "$1" = alpha ]; then echo "an alpha"; else echo "a $1"; fi
}

# Removes the version folders other than $1 (and unfinished *.tmp ones) from $home/cli.
remove_others() {
  for d in "$home/cli"/*/; do
    [ -d "$d" ] || continue
    v="$(basename "$d")"
    [ "$v" = "$1" ] && continue
    case "$v" in
      *.tmp) ;;
      *) [ -n "$(version_type "$v")" ] || continue ;;
    esac
    rm -rf "$d" 2>/dev/null || say "Could not remove ${d%/} (the next install removes it)."
  done
}

dev_flag=""
archive=""
version="${VERITWIN_VERSION:-}"
home="${VERITWIN_HOME:-${HOME:?HOME is not set}/.veritwin}"
bin_dir="${VERITWIN_BIN_DIR:-$HOME/.local/bin}"
releases_url="${VERITWIN_RELEASES_URL:-https://github.com/Veritwin/token-swap-cli/releases/download}"
registry="${VERITWIN_NPM_REGISTRY:-https://registry.npmjs.org}"
registry="${registry%/}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dev) dev_flag=1 ;;
    --archive | --version | --home | --bin-dir)
      [ $# -ge 2 ] || die "$1 needs a value."
      case "$1" in
        --archive) archive="$2" ;;
        --version) version="$2" ;;
        --home) home="$2" ;;
        --bin-dir) bin_dir="$2" ;;
      esac
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "Unknown option: $1 (see --help)." ;;
  esac
  shift
done

if [ -n "$RELEASE_TYPE" ]; then
  [ -z "$dev_flag" ] || die "This installer is for $RELEASE_TYPE releases and takes no type option."
  type="$RELEASE_TYPE"
else
  [ -n "$dev_flag" ] || die "This copy has no release type: run it with --dev, or use the install address for alpha or prod."
  type=dev
fi
[ -z "$archive" ] || [ -z "$version" ] || die "--version and --archive can't be used together."

# --- The platform -------------------------------------------------------------------------------
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) os="" ;;
esac
case "$arch" in
  x86_64 | amd64) arch=x64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) arch="" ;;
esac
if [ -z "$os" ] || [ -z "$arch" ]; then
  die "There is no build for this platform ($(uname -s) $(uname -m)). Builds exist for macOS (arm64, x64), Linux (x64, arm64) and Windows (x64, arm64)."
fi
# A Mac under Rosetta gets the arm64 build.
if [ "$os" = darwin ] && [ "$arch" = x64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
  arch=arm64
fi
if [ "$os" = linux ] && (ldd --version 2>&1 || true) | grep -qi musl; then
  die "There is no build for musl Linux (e.g. Alpine): Node.js has no official build for it."
fi
platform="$os-$arch"

work="$(mktemp -d "${TMPDIR:-/tmp}/veritwin-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# --- The version --------------------------------------------------------------------------------
if [ -n "$archive" ]; then
  [ -f "$archive" ] || die "No such archive: $archive"
  top="$(tar -tzf "$archive" 2>/dev/null | head -n 1 | sed 's#/.*##')" || true
  case "$top" in
    veritwin-*-"$platform") version="${top#veritwin-}" && version="${version%-"$platform"}" ;;
    veritwin-*) die "$archive is not for this platform ($platform)." ;;
    *) die "$archive is not a Veritwin CLI build." ;;
  esac
elif [ -z "$version" ]; then
  if [ "$type" = dev ]; then
    command -v gh >/dev/null 2>&1 ||
      die "Dev releases need gh (GitHub's CLI), logged in to an account that can read $DEV_REPO."
    tags="$(gh release list -R "$DEV_REPO" --json tagName --limit 100 --jq '.[].tagName')" ||
      die "gh could not list the releases of $DEV_REPO."
    # The highest cli-v<X.Y.Z-dev.N>, compared part by part as numbers.
    version="$(printf '%s\n' "$tags" | grep -E "^cli-v$num\.$num\.$num-dev\.$num\$" |
      sed 's/^cli-v//; s/-dev\./ /; s/\./ /g' | sort -k1,1n -k2,2n -k3,3n -k4,4n | tail -n 1 |
      awk 'NF == 4 { print $1 "." $2 "." $3 "-dev." $4 }')" || true
    [ -n "$version" ] || die "No dev release yet."
  else
    command -v curl >/dev/null 2>&1 || die "This installer needs curl."
    tags_url="$registry/-/package/@veritwin%2fcli/dist-tags"
    code="$(curl -sSL -o "$work/dist-tags" -w '%{http_code}' "$tags_url")" ||
      die "Could not reach the npm registry ($tags_url)."
    tag=alpha
    if [ "$type" = prod ]; then tag=latest; fi
    case "$code" in
      200) version="$(sed -n "s/.*\"$tag\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$work/dist-tags")" ;;
      401 | 404) version="" ;;
      *) die "The npm registry answered $code ($tags_url)." ;;
    esac
    if [ "$type" = prod ] && [ "$(version_type "$version")" != prod ]; then
      die "No prod release yet. For alpha, use $PAGES/alpha/install.sh"
    fi
    [ -n "$version" ] || die "No $type release yet."
  fi
fi
vtype="$(version_type "$version")"
[ -n "$vtype" ] || die "\"$version\" is not a CLI version: expected X.Y.Z (prod), X.Y.Z-alpha.N or X.Y.Z-dev.N."
[ "$vtype" = "$type" ] || die "$version is not $(an "$type") version: use the installer of its type."

dir="$home/cli/$version"
wrapper="$bin_dir/veritwin"
target="$dir/bin/veritwin"
if [ -x "$target" ] && [ -f "$wrapper" ] && grep -qF "$target" "$wrapper"; then
  remove_others "$version"
  say "$NAME $version ($type) is already installed."
  exit 0
fi

# --- Download and check -------------------------------------------------------------------------
name="veritwin-$version-$platform.tar.gz"
if [ -z "$archive" ]; then
  if [ "$type" = dev ]; then
    command -v gh >/dev/null 2>&1 ||
      die "Dev releases need gh (GitHub's CLI), logged in to an account that can read $DEV_REPO."
    gh release download "cli-v$version" -R "$DEV_REPO" -p "$name" -p SHA256SUMS -D "$work" >/dev/null 2>&1 ||
      die "No dev release $version (or it has no $platform build)."
  else
    command -v curl >/dev/null 2>&1 || die "This installer needs curl."
    url="$releases_url/v$version"
    if ! curl -fsSL -o "$work/$name" "$url/$name" 2>/dev/null ||
      ! curl -fsSL -o "$work/SHA256SUMS" "$url/SHA256SUMS" 2>/dev/null; then
      die "No $type release $version (or it has no $platform build): $url/$name"
    fi
  fi
  expected="$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "$work/SHA256SUMS")"
  [ -n "$expected" ] || die "SHA256SUMS lists no $name: nothing was installed."
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$work/$name" | cut -d ' ' -f 1)"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$work/$name" | cut -d ' ' -f 1)"
  else
    die "This installer needs sha256sum or shasum."
  fi
  [ "$expected" = "$actual" ] ||
    die "The download's checksum doesn't match SHA256SUMS: nothing was installed."
  archive="$work/$name"
fi

# --- Install ------------------------------------------------------------------------------------
previous=""
if [ -d "$home/cli" ]; then
  for d in "$home/cli"/*/; do
    [ -d "$d" ] || continue
    v="$(basename "$d")"
    if [ "$v" != "$version" ] && [ -n "$(version_type "$v")" ]; then previous="$v"; fi
  done
fi

mkdir -p "$home/cli"
rm -rf "$dir.tmp"
mkdir "$dir.tmp"
tar -xzf "$archive" -C "$dir.tmp" --strip-components 1 ||
  die "Could not extract $archive: nothing was installed."
[ -x "$dir.tmp/bin/veritwin" ] || die "$archive holds no bin/veritwin: nothing was installed."
rm -rf "$dir"
mv "$dir.tmp" "$dir"

mkdir -p "$bin_dir"
quoted="$(printf '%s' "$target" | sed "s/'/'\\\\''/g")"
printf '#!/bin/sh\nexec '"'"'%s'"'"' "$@"\n' "$quoted" >"$wrapper.tmp$$"
chmod 755 "$wrapper.tmp$$"
mv -f "$wrapper.tmp$$" "$wrapper"
printf '%s\n' "$bin_dir" >"$home/cli/bin-dir"

remove_others "$version"

# --- Report -------------------------------------------------------------------------------------
if [ -n "$previous" ]; then
  say "Replaced $(version_type "$previous") $previous with $type $version."
else
  say "Installed $NAME $version ($type)."
fi
case ":${PATH:-}:" in
  *":$bin_dir:"*) on_path=1 ;;
  *) on_path="" ;;
esac
first="$(command -v veritwin 2>/dev/null || true)"
if [ -z "$on_path" ]; then
  say "$bin_dir is not on your PATH. Add this line to your shell's profile (e.g. ~/.zshrc or ~/.bashrc):"
  say "  export PATH=\"$bin_dir:\$PATH\""
fi
if [ -n "$first" ] && [ "$first" != "$wrapper" ]; then
  say "Another veritwin comes first on your PATH: $first (an npm install?). Remove it, or put $bin_dir before it."
fi
say "Run: veritwin --version"
