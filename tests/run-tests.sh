#!/usr/bin/env bash
# ==============================================================================
# run-tests.sh - Self-contained test suite for SpotX-Termux
#
# Runs anywhere bash runs (CI on Ubuntu, Termux, Git Bash): no test framework,
# no Android, no container. Android/PRoot/apt are replaced by small fakes on PATH
# and every test works inside a throwaway HOME/PREFIX.
#
# Usage: bash tests/run-tests.sh
# ==============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
SKIPPED=0

# ------------------------------------------------------------------------------
# Minimal assertion helpers
# ------------------------------------------------------------------------------
section() { echo; echo "== $1"; }
pass()    { PASSED=$((PASSED + 1)); echo "  ok   $1"; }
fail()    { FAILED=$((FAILED + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }
skip()    { SKIPPED=$((SKIPPED + 1)); echo "  skip $1"; }

assert_eq() { # <description> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}
assert_ok() { # <description> <command...>
    local d="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d" "command failed: $*"; fi
}
assert_fails() { # <description> <command...>
    local d="$1"; shift
    if "$@" >/dev/null 2>&1; then fail "$d" "command unexpectedly succeeded: $*"; else pass "$d"; fi
}

# Prints the definition of the named functions from a script, so functions that
# live in executable scripts (not libraries) can be tested in isolation.
extract_functions() { # <file> <function...>
    local file="$1"; shift
    local fn
    for fn in "$@"; do
        sed -n "/^${fn}() {/,/^}/p" "$file"
    done
}

# Fresh sandbox: HOME, PREFIX, TMPDIR and a bin dir for fakes, exported for children
new_sandbox() {
    SANDBOX="$(mktemp -d "${WORK}/sb.XXXXXX")"
    mkdir -p "$SANDBOX/home" "$SANDBOX/prefix/tmp" "$SANDBOX/prefix/bin" "$SANDBOX/fakebin"
    export HOME="$SANDBOX/home" PREFIX="$SANDBOX/prefix" TMPDIR="$SANDBOX/prefix/tmp"
    export PATH="$SANDBOX/fakebin:$ORIG_PATH"
}
ORIG_PATH="$PATH"

# Loads common.sh in the current shell (inside a sandbox)
load_common() {
    # shellcheck source=../src/common.sh
    source "$REPO/src/common.sh"
}

# ==============================================================================
# Static checks on the repository
# ==============================================================================
section "repository layout"

for f in install.sh uninstall.sh src/*.sh src/guest/*.sh; do
    if [ "$(head -c 2 "$REPO/$f")" = "#!" ]; then pass "shebang: $f"; else fail "shebang: $f"; fi
done
for f in install.sh uninstall.sh src/*.sh src/guest/*.sh src/guest/*.rc VERSION; do
    if grep -q $'\r' "$REPO/$f"; then fail "LF line endings: $f" "contains CR characters"; else pass "LF line endings: $f"; fi
done
assert_ok "VERSION is CalVer" grep -Eq '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$' "$REPO/VERSION"

(
    new_sandbox; load_common
    for entry in "${SPOTX_HOST_FILES[@]}"; do
        rel="${entry%%|*}"
        [ -f "$REPO/$rel" ] && echo "ok host file exists: $rel" || echo "FAIL host file listed but missing: $rel"
    done
    for name in "${SPOTX_GUEST_FILES[@]}"; do
        [ -f "$REPO/src/guest/$name" ] && echo "ok guest file exists: src/guest/$name" || echo "FAIL guest file listed but missing: src/guest/$name"
    done
) > "$WORK/layout.txt"
while read -r status rest; do
    if [ "$status" = "ok" ]; then pass "$rest"; else fail "$rest"; fi
done < "$WORK/layout.txt"

# ==============================================================================
# common.sh: validation and version helpers
# ==============================================================================
section "common.sh: validators"
(
    new_sandbox; load_common
    is_valid_version "2026.10.11"   && echo "v1=ok"
    is_valid_version "2026.10.11.1" && echo "v2=ok"
    is_valid_version "404:NotFound" || echo "v3=ok"
    is_valid_version ""             || echo "v4=ok"
    printf '#!/bin/sh\n' > "$HOME/ok.sh";  is_valid_script "$HOME/ok.sh"  && echo "s1=ok"
    printf '404: Not Found' > "$HOME/bad"; is_valid_script "$HOME/bad"    || echo "s2=ok"
    : > "$HOME/empty";                     is_valid_script "$HOME/empty"  || echo "s3=ok"
) > "$WORK/out.txt"
for k in v1 v2 v3 v4 s1 s2 s3; do
    assert_ok "validator case $k" grep -qx "$k=ok" "$WORK/out.txt"
done

section "common.sh: version_gt"
(
    new_sandbox; load_common
    for c in "2026.11.16>2026.10.11" "2026.10.11.1>2026.10.11" "2026.10.11.10>2026.10.11.9" \
             "2026.10.11<2026.10.11.1" "2026.10.11=2026.10.11" "2026.09.30<2026.10.01"; do
        if [[ "$c" == *">"* ]]; then left="${c%%>*}"; right="${c#*>}"; want=0
        elif [[ "$c" == *"<"* ]]; then left="${c%%<*}"; right="${c#*<}"; want=1
        else left="${c%%=*}"; right="${c#*=}"; want=1; fi
        version_gt "$left" "$right"; got=$?
        [ "$got" = "$want" ] && echo "ok $c" || echo "FAIL $c"
    done
) > "$WORK/out.txt"
while read -r status rest; do
    if [ "$status" = "ok" ]; then pass "version_gt: $rest"; else fail "version_gt: $rest"; fi
done < "$WORK/out.txt"

section "common.sh: version markers"
out="$(
    new_sandbox; load_common
    echo "2026.01.01" > "$HOME/.spotx-termux-version"   # legacy marker of older installs
    write_version_markers "2026.11.16"
    write_version_markers "404:NotFound"   # must be ignored
    echo "$(cat "$SPOTX_DIR/VERSION") legacy=$([ -e "$HOME/.spotx-termux-version" ] && echo kept || echo removed)"
)"
assert_eq "single marker written, invalid ignored, legacy marker migrated" "2026.11.16 legacy=removed" "$out"

out="$(
    new_sandbox
    mkdir -p "$HOME/.spotx-termux"; cp "$REPO/src/common.sh" "$HOME/.spotx-termux/"
    echo "garbage" > "$HOME/.spotx-termux/VERSION"
    echo "2026.01.02" > "$HOME/.spotx-termux-version"
    # shellcheck source=../src/common.sh
    source "$HOME/.spotx-termux/common.sh"
    echo "$SPOTX_TERMUX_VERSION"
)"
assert_eq "resolve_spotx_version skips an invalid marker" "2026.01.02" "$out"

out="$(new_sandbox; load_common; echo "$SPOTX_REPO_ROOT")"
assert_eq "SPOTX_REPO_ROOT detected from a checkout" "$REPO" "$out"

section "common.sh: missing_pkgs / prompt_tty"
out="$(new_sandbox; load_common; missing_pkgs "bash|bash" "fakepkg|definitely-not-a-command-xyz" "sed|sed")"
assert_eq "missing_pkgs reports only absent commands" "fakepkg" "$out"
out="$(new_sandbox; load_common; ans=""; prompt_tty "q? " ans "N" < /dev/null; echo "$ans")"
if [ -t 0 ] || { : < /dev/tty; } 2>/dev/null; then
    skip "prompt_tty default without a terminal (a terminal is attached)"
else
    assert_eq "prompt_tty falls back to the default without a terminal" "N" "$out"
fi

# ==============================================================================
# common.sh: host installation helpers
# ==============================================================================
section "common.sh: wrappers and shortcuts"
(
    new_sandbox; load_common
    install_wrappers
    install_widget_shortcuts >/dev/null 2>&1
    printf '#!/bin/bash\necho "args: $*"\n' > "$HOME/start-spotify.sh"
    echo "stop=$(bash "$TERMUX_BIN/spotify-stop" a b)"
    echo "plain=$(bash "$TERMUX_BIN/spotify" --version)"
    echo "widget=$(bash "$SHORTCUTS_DIR/Spotify-Stop")"
    echo "count=$(ls "$TERMUX_BIN" | wc -l | tr -d ' ')"
    echo "shebang=$(head -1 "$TERMUX_BIN/spotify")"
) > "$WORK/out.txt"
assert_ok "spotify-stop forwards --stop plus user args" grep -qx "stop=args: --stop a b" "$WORK/out.txt"
assert_ok "spotify forwards user args" grep -qx "plain=args: --version" "$WORK/out.txt"
assert_ok "widget Spotify-Stop is a wrapper" grep -qx "widget=args: --stop" "$WORK/out.txt"
assert_ok "six command wrappers installed" grep -qx "count=6" "$WORK/out.txt"
assert_ok "wrappers use the Termux shebang" grep -qx "shebang=#!/data/data/com.termux/files/usr/bin/bash" "$WORK/out.txt"

section "common.sh: sync_host_scripts is all-or-nothing"
(
    new_sandbox; load_common
    sync_host_scripts >/dev/null 2>&1 && echo "first=ok"
    echo "# old" > "$HOME/start-spotify.sh"
    SPOTX_HOST_FILES+=("src/does-not-exist.sh|$HOME/nope.sh")
    SPOTX_REPO_RAW="http://127.0.0.1:9"
    sync_host_scripts >/dev/null 2>&1 || echo "second=failed"
    echo "kept=$(cat "$HOME/start-spotify.sh")"
    echo "leftovers=$(find "$HOME" -name '*.staged.*' -o -name '*.tmp.*' | wc -l | tr -d ' ')"
) > "$WORK/out.txt"
assert_ok "sync from checkout succeeds" grep -qx "first=ok" "$WORK/out.txt"
assert_ok "sync with one invalid file fails" grep -qx "second=failed" "$WORK/out.txt"
assert_ok "no installed file replaced on failure" grep -qx "kept=# old" "$WORK/out.txt"
assert_ok "no temporary files left behind" grep -qx "leftovers=0" "$WORK/out.txt"

section "common.sh: stage_guest_bundle"
(
    new_sandbox; load_common
    stage_guest_bundle >/dev/null 2>&1 && echo "staged=ok"
    echo "files=$(cd "$GUEST_STAGING_DIR" && find . -type f | LC_ALL=C sort | tr '\n' ' ')"
    remove_guest_bundle
    [ -d "$GUEST_STAGING_DIR" ] || echo "removed=ok"
) > "$WORK/out.txt"
assert_ok "bundle staged" grep -qx "staged=ok" "$WORK/out.txt"
assert_eq "bundle mirrors the src/ layout" \
    "files=./guest-setup.sh ./guest/box64-spotify.rc ./guest/spotify-box64-wrapper.sh ./guest/spotify-termux.sh " \
    "$(grep '^files=' "$WORK/out.txt")"
assert_ok "bundle removed" grep -qx "removed=ok" "$WORK/out.txt"

# ==============================================================================
# common.sh: probe_container with a fake proot-distro
# ==============================================================================
# The fake maps container paths (/tmp, /usr/local/lib) onto sandbox directories.
make_fake_proot() {
    mkdir -p "$SANDBOX/rootfs/usr/local/lib/spotx-termux"
    cat > "$SANDBOX/fakebin/proot-distro" <<EOF
#!/usr/bin/env bash
[ "\$1" = login ] || exit 1
shift 2
[ "\${1:-}" = --shared-tmp ] && shift
shift
args=()
for a in "\$@"; do
    a="\${a/#\/tmp\//$SANDBOX/prefix/tmp/}"
    a="\${a/#\/usr\/local\/lib\//$SANDBOX/rootfs/usr/local/lib/}"
    args+=("\$a")
done
exec "\${args[@]}"
EOF
    chmod +x "$SANDBOX/fakebin/proot-distro"
}

section "common.sh: probe_container"
out="$(new_sandbox; make_fake_proot; load_common; probe_container >/dev/null 2>&1; echo "$GUEST_PROBE_API $GUEST_RESPONSIVE $GUEST_ELF")"
assert_eq "probe via staged checkout copy" "1 yes missing" "$out"

out="$(new_sandbox; make_fake_proot; load_common; SPOTX_REPO_ROOT=""
       cp "$REPO/src/guest-setup.sh" "$SANDBOX/rootfs/usr/local/lib/spotx-termux/guest-setup.sh"
       probe_container >/dev/null 2>&1; echo "$GUEST_RESPONSIVE")"
assert_eq "probe via the copy installed in the container (offline)" "yes" "$out"

out="$(new_sandbox; make_fake_proot; load_common; SPOTX_REPO_ROOT=""; SPOTX_REPO_RAW="http://127.0.0.1:9"
       probe_container >/dev/null 2>&1 && echo "rc=0" || echo "rc=1 [$GUEST_RESPONSIVE]")"
assert_eq "probe fails cleanly when no script is available" "rc=1 []" "$out"

out="$(
    new_sandbox; make_fake_proot
    mkdir -p "$SANDBOX/oldrepo/src"
    cp "$REPO/src/common.sh" "$SANDBOX/oldrepo/src/"; cp "$REPO/install.sh" "$REPO/VERSION" "$SANDBOX/oldrepo/"
    printf '#!/bin/bash\ntouch "%s/OLD-RAN"\n' "$SANDBOX" > "$SANDBOX/oldrepo/src/guest-setup.sh"
    # shellcheck source=../src/common.sh
    source "$SANDBOX/oldrepo/src/common.sh"
    probe_container >/dev/null 2>&1
    [ -e "$SANDBOX/OLD-RAN" ] && echo "executed" || echo "refused"
)"
assert_eq "a guest-setup.sh without --probe support is never executed" "refused" "$out"

# ==============================================================================
# Release pinning with a fake GitHub (fake curl serving $SANDBOX/gh/<ref>/<path>)
# ==============================================================================
make_fake_github() { # <main VERSION> [tag VERSION]
    local main_ver="$1" tag_ver="${2:-}"
    mkdir -p "$SANDBOX/gh/main/src"
    echo "$main_ver" > "$SANDBOX/gh/main/VERSION"
    cp "$REPO/src/common.sh" "$SANDBOX/gh/main/src/common.sh"
    if [ -n "$tag_ver" ]; then
        mkdir -p "$SANDBOX/gh/v$tag_ver/src"
        echo "$tag_ver" > "$SANDBOX/gh/v$tag_ver/VERSION"
        cp "$REPO/src/common.sh" "$SANDBOX/gh/v$tag_ver/src/common.sh"
        printf '#!/usr/bin/env bash\necho "TAGGED-INSTALLER ref=$SPOTX_REPO_REF args=$*"\n' > "$SANDBOX/gh/v$tag_ver/install.sh"
    fi
    cat > "$SANDBOX/fakebin/curl" <<EOF
#!/usr/bin/env bash
out=""; url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        --connect-timeout|--max-time) shift 2 ;;
        -*) shift ;;
        *) url="\$1"; shift ;;
    esac
done
path="\${url%%\?*}"; path="\${path#https://fake.example/}"
[ -f "$SANDBOX/gh/\$path" ] || exit 22
if [ -n "\$out" ]; then cp "$SANDBOX/gh/\$path" "\$out"; else cat "$SANDBOX/gh/\$path"; fi
EOF
    chmod +x "$SANDBOX/fakebin/curl"
    export SPOTX_REPO_BASE="https://fake.example"
}

section "common.sh: release pinning"
out="$(new_sandbox; make_fake_github 2026.12.01 2026.12.01; load_common
       echo "latest=$(latest_published_version)"
       use_release_ref 2026.12.01 && echo "ref=$SPOTX_REPO_REF raw=${SPOTX_REPO_RAW#https://fake.example/}")"
assert_eq "tag present: downloads pinned to it" $'latest=2026.12.01\nref=v2026.12.01 raw=v2026.12.01' "$out"
out="$(new_sandbox; make_fake_github 2026.12.01; load_common
       use_release_ref 2026.12.01 || echo "ref=$SPOTX_REPO_REF")"
assert_eq "tag missing: downloads stay on main" "ref=main" "$out"
out="$(new_sandbox; make_fake_github "404: Not Found"; load_common; latest_published_version)"
assert_eq "invalid published VERSION is reported as unknown" "unknown" "$out"

section "install.sh: bootstrap follows the release tag"
out="$(new_sandbox; make_fake_github 2026.12.01 2026.12.01; unset SPOTX_REPO_REF
       bash -c "$(cat "$REPO/install.sh")" install.sh --version 2>&1)"
assert_eq "one-liner re-runs the installer of the tagged release" "TAGGED-INSTALLER ref=v2026.12.01 args=--version" "$out"
out="$(new_sandbox; make_fake_github 2026.12.01; unset SPOTX_REPO_REF
       bash -c "$(cat "$REPO/install.sh")" install.sh --version 2>&1)"
assert_eq "no tag yet: installs from main as before" "SpotX-Termux 2026.12.01" "$out"

# ==============================================================================
# start-spotify.sh: single-session guard
# ==============================================================================
section "start-spotify.sh: session lock"
(
    new_sandbox; load_common
    eval "$(extract_functions "$REPO/src/start-spotify.sh" session_owner_alive acquire_session_lock release_session_lock)"
    acquire_session_lock && echo "first=ok"
    [ "$(cat "$SESSION_LOCK")" = "$$" ] && echo "owner=self"
    bash -c 'exec -a spotify-owner sleep 30' & owner=$!
    sleep 0.3
    echo "$owner" > "$SESSION_LOCK"
    acquire_session_lock || echo "live=refused"
    kill "$owner"; wait "$owner" 2>/dev/null
    acquire_session_lock && echo "stale=taken"
    release_session_lock
    [ -e "$SESSION_LOCK" ] || echo "released=ok"
) > "$WORK/out.txt" 2>/dev/null
assert_ok "first launcher takes the lock" grep -qx "first=ok" "$WORK/out.txt"
assert_ok "lock records the launcher PID" grep -qx "owner=self" "$WORK/out.txt"
if [ -r /proc/self/cmdline ]; then
    assert_ok "second launcher refused while the owner lives" grep -qx "live=refused" "$WORK/out.txt"
else
    skip "second launcher refused (no /proc on this platform)"
fi
assert_ok "stale lock is taken over" grep -qx "stale=taken" "$WORK/out.txt"
assert_ok "lock released by its owner" grep -qx "released=ok" "$WORK/out.txt"

section "start-spotify.sh: environment passed to the container"
# Full launcher run with a fake proot-distro that records its arguments and exits
# (Spotify "closes" immediately, so the launcher then runs its cleanup and returns).
scale_run() { # [SPOTIFY_SCALE value] -> prints the recorded guest command line
    (
        new_sandbox
        printf '#!/usr/bin/env bash\necho "$*" >> "%s/proot.log"\n' "$SANDBOX" > "$SANDBOX/fakebin/proot-distro"
        chmod +x "$SANDBOX/fakebin/proot-distro"
        if [ -n "${1:-}" ]; then export SPOTIFY_SCALE="$1"; else unset SPOTIFY_SCALE; fi
        timeout 60 bash "$REPO/src/start-spotify.sh" >/dev/null 2>&1 < /dev/null
        cat "$SANDBOX/proot.log" 2>/dev/null
    )
}
out="$(scale_run 1.75)"
if [[ "$out" == *"SPOTIFY_SCALE=1.75"* ]]; then pass "SPOTIFY_SCALE reaches the container"; else fail "SPOTIFY_SCALE reaches the container" "$out"; fi
out="$(scale_run "")"
if [[ "$out" == *"spotify-termux"* && "$out" != *"SPOTIFY_SCALE"* ]]; then
    pass "no SPOTIFY_SCALE passed when unset (runner default applies)"
else
    fail "no SPOTIFY_SCALE passed when unset (runner default applies)" "$out"
fi

# ==============================================================================
# guest-setup.sh
# ==============================================================================
section "guest-setup.sh: --probe"
out="$(bash "$REPO/src/guest-setup.sh" --probe 2>/dev/null)"
for key in GUEST_PROBE_API GUEST_RESPONSIVE GUEST_BOX64_VER GUEST_BOX64_GPU GUEST_WM GUEST_ELF GUEST_VER GUEST_SPOTX GUEST_RUNNER GUEST_PLAYERCTL; do
    if grep -q "^${key}=" <<< "$out"; then pass "probe reports $key"; else fail "probe reports $key"; fi
done
(
    new_sandbox; load_common
    missing=()
    for key in $(sed -n 's/^\(GUEST_[A-Z0-9_]*\)=.*/\1/p' <<< "$out"); do
        [[ " ${GUEST_PROBE_KEYS[*]} " == *" $key "* ]] || missing+=("$key")
    done
    echo "${missing[*]:-none}"
) > "$WORK/out.txt"
assert_eq "host parses every key the probe emits" "none" "$(cat "$WORK/out.txt")"

section "guest-setup.sh: SpotX patch detection"
if command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    d="$WORK/spa"; mkdir -p "$d/stock" "$d/patched" "$d/snap" "$d/Apps"
    # Large enough that 'grep -q' exits before unzip finishes (SIGPIPE under pipefail)
    head -c 3000000 /dev/urandom | base64 > "$d/stock/xpui.js"
    { cat "$d/stock/xpui.js"; printf '\n//# SpotX was here\n'; } > "$d/patched/xpui.js"
    cp "$d/stock/xpui.js" "$d/snap/xpui.js"; printf '//# SpotX was here\n' > "$d/snap/xpui-snapshot.js"
    for v in stock patched snap; do (cd "$d/$v" && zip -q -r "../$v.spa" .); done
    cp "$d/stock.spa" "$d/Apps/xpui.spa"; touch "$d/Apps/xpui.bak" "$d/spotify.bak"
    eval "$(extract_functions "$REPO/src/guest-setup.sh" spotx_patch_state)"
    for c in "stock:not_applied" "patched:applied" "snap:applied" "absent:missing_xpui"; do
        XPUI_SPA="$d/${c%%:*}.spa"
        assert_eq "patch state: ${c%%:*}" "${c#*:}" "$(set -o pipefail; spotx_patch_state)"
    done
    # shellcheck disable=SC2034  # read by spotx_patch_state, loaded via eval
    XPUI_SPA="$d/Apps/xpui.spa"
    assert_eq "patch state: stock xpui.spa next to stale SpotX backups" "not_applied" "$(spotx_patch_state)"
else
    skip "SpotX patch detection (zip/unzip not available)"
fi

section "guest-setup.sh: apt_install_set"
# Fake apt-get: every package is known except those in $APT_UNKNOWN; the pair in
# $APT_CONFLICT fails only when both are requested in the same call.
make_fake_apt() {
    cat > "$SANDBOX/fakebin/apt-get" <<'EOF'
#!/usr/bin/env bash
sim=0; pkgs=()
for a in "$@"; do case "$a" in -s) sim=1 ;; -*|install) ;; *) pkgs+=("$a") ;; esac; done
for p in "${pkgs[@]}"; do [[ " ${APT_UNKNOWN:-} " == *" $p "* ]] && exit 100; done
if [ -n "${APT_CONFLICT:-}" ] && [ ${#pkgs[@]} -gt 1 ]; then
    read -r c1 c2 <<< "$APT_CONFLICT"
    [[ " ${pkgs[*]} " == *" $c1 "* && " ${pkgs[*]} " == *" $c2 "* ]] && exit 100
fi
[ "$sim" = 0 ] && echo "INSTALL ${pkgs[*]}" >> "$APT_LOG"
exit 0
EOF
    chmod +x "$SANDBOX/fakebin/apt-get"
}
apt_case() { # <unknown> <conflict> <mode> <pkgs...>  -> prints apt log lines + "rc=N"
    local unknown="$1" conflict="$2"; shift 2
    (
        new_sandbox; make_fake_apt
        export APT_LOG="$SANDBOX/apt.log" APT_UNKNOWN="$unknown" APT_CONFLICT="$conflict"
        : > "$APT_LOG"
        info() { :; }; warn() { :; }; error() { :; }
        eval "$(extract_functions "$REPO/src/guest-setup.sh" apt_installable apt_install_set)"
        ( apt_install_set "$@" ) >/dev/null 2>&1; rc=$?
        cat "$APT_LOG"; echo "rc=$rc"
    )
}
assert_eq "all available: a single apt-get call" $'INSTALL a b c\nrc=0' "$(apt_case "" "" required x a b c)"
assert_eq "optional package missing: the rest is installed" $'INSTALL a c\nrc=0' "$(apt_case "b" "" optional x a b c)"
assert_eq "required package missing: setup aborts" $'INSTALL a c\nrc=1' "$(apt_case "b" "" required x a b c)"
assert_eq "t64 name unavailable: old name chosen" $'INSTALL a libgtk-3-0\nrc=0' "$(apt_case "libgtk-3-0t64" "" required x a "libgtk-3-0t64|libgtk-3-0")"
assert_eq "conflict only in combination: one package at a time" $'INSTALL a\nINSTALL b\nINSTALL c\nrc=0' "$(apt_case "" "b c" optional x a b c)"

section "guest-setup.sh: install_guest_file"
(
    new_sandbox; load_common
    stage_guest_bundle >/dev/null 2>&1
    error() { :; }
    eval "$(extract_functions "$REPO/src/guest-setup.sh" is_valid_guest_file install_guest_file)"
    # Both read by install_guest_file, loaded via eval (invisible to shellcheck)
    # shellcheck disable=SC2034
    GUEST_FILES_DIR="$GUEST_STAGING_DIR/guest"
    # shellcheck disable=SC2034
    GUEST_REPO_RAW="http://127.0.0.1:9"
    root="$SANDBOX/root"; mkdir -p "$root"
    install_guest_file spotify-termux.sh "$root/bin/spotify-termux" 755
    cmp -s "$root/bin/spotify-termux" "$REPO/src/guest/spotify-termux.sh" && echo "runner=identical"
    [ -x "$root/bin/spotify-termux" ] && echo "runner=executable"
    install_guest_file box64-spotify.rc "$root/.box64rc" 644
    grep -q '^\[spotify\]' "$root/.box64rc" && echo "rc=installed"
    rm -f "$GUEST_FILES_DIR/spotify-termux.sh"
    ( install_guest_file spotify-termux.sh "$root/x" 755 ) >/dev/null 2>&1 || echo "missing=aborted"
    echo "404: Not Found" > "$GUEST_FILES_DIR/box64-spotify.rc"
    ( install_guest_file box64-spotify.rc "$root/y.rc" 644 ) >/dev/null 2>&1 || echo "errorpage=rejected"
) > "$WORK/out.txt"
assert_ok "runner installed from the staged bundle" grep -qx "runner=identical" "$WORK/out.txt"
assert_ok "runner is executable" grep -qx "runner=executable" "$WORK/out.txt"
assert_ok "Box64 rc installed" grep -qx "rc=installed" "$WORK/out.txt"
assert_ok "missing file without network aborts setup" grep -qx "missing=aborted" "$WORK/out.txt"
assert_ok "staged HTTP error page is rejected" grep -qx "errorpage=rejected" "$WORK/out.txt"

section "guest: Box64 wrapper takes its settings from box64-spotify.rc"
# Fake box64 prints the environment it receives; the wrapper runs under POSIX sh
wrapper_env() { # <rc path> -> sorted BOX64_* environment seen by box64
    (
        new_sandbox
        printf '#!/bin/sh\nenv | grep "^BOX64_" | grep -v "^BOX64_LD_LIBRARY_PATH=" | LC_ALL=C sort\n' > "$SANDBOX/fakebin/box64"
        chmod +x "$SANDBOX/fakebin/box64"
        SPOTX_BOX64_RC="$1" sh "$REPO/src/guest/spotify-box64-wrapper.sh"
    )
}
expected="$(grep -E '^BOX64_[A-Z0-9_]+=' "$REPO/src/guest/box64-spotify.rc" | LC_ALL=C sort)"
assert_eq "every BOX64_* line of the rc is exported" "$expected" "$(wrapper_env "$REPO/src/guest/box64-spotify.rc")"
assert_ok "rc keeps BOX64_INPROCESSGPU=0 (Spotify zygote crash otherwise)" grep -qx 'BOX64_INPROCESSGPU=0' "$REPO/src/guest/box64-spotify.rc"
assert_eq "rc missing: crash-safe minimum still exported" "BOX64_INPROCESSGPU=0" "$(wrapper_env /nonexistent)"

# ==============================================================================
# Entry points start and report a version
# ==============================================================================
section "entry points"
for s in install.sh uninstall.sh src/start-spotify.sh src/update-spotify.sh src/doctor.sh src/control-spotify.sh; do
    out="$(new_sandbox; bash "$REPO/$s" --version 2>&1)"
    if [[ "$out" == "SpotX-Termux "* ]]; then pass "$s --version"; else fail "$s --version" "$out"; fi
done

# ==============================================================================
echo
echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"
[ "$FAILED" -eq 0 ]
