#!/bin/sh
# Box64 wrapper for Spotify Desktop Client on ARM64
# Installed by guest-setup.sh as /usr/bin/spotify (aarch64 only).
#
# The BOX64_* settings have a single source: box64-spotify.rc, installed by
# guest-setup.sh as /usr/local/lib/spotx-termux/box64-spotify.rc (and merged into
# the Box64 rc files). They are also exported here because the environment applies
# even if Box64 does not pick up the [spotify] rc section.
SPOTX_BOX64_RC="${SPOTX_BOX64_RC:-/usr/local/lib/spotx-termux/box64-spotify.rc}"

if [ -r "$SPOTX_BOX64_RC" ]; then
    # shellcheck disable=SC2163  # exporting the NAME=value held in $line is intended
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            BOX64_[A-Z0-9_]*=*) export "$line" ;;
        esac
    done < "$SPOTX_BOX64_RC"
else
    # rc file missing: keep at least the setting without which Spotify's zygote crashes
    export BOX64_INPROCESSGPU=0
fi

export BOX64_LD_LIBRARY_PATH="/usr/share/spotify:${BOX64_LD_LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="/usr/share/spotify:${LD_LIBRARY_PATH:-}"
exec box64 /usr/share/spotify/spotify "$@"
