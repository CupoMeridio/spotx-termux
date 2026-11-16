#!/bin/sh
# Box64 wrapper for Spotify Desktop Client on ARM64
# Installed by guest-setup.sh as /usr/bin/spotify (aarch64 only).
# The BOX64_* values mirror box64-spotify.rc on purpose: the environment applies
# even if Box64 does not pick up the [spotify] rc section. Keep the two in sync.
export BOX64_NOBANNER=1
export BOX64_LOG=0
export BOX64_DYNAREC=1
export BOX64_NOSANDBOX=1
export BOX64_INPROCESSGPU=0
export BOX64_MALLOC_HACK=2
export BOX64_DYNAREC_STRONGMEM=1
export BOX64_DYNAREC_BIGBLOCK=1
export BOX64_DYNAREC_FASTNAN=1
export BOX64_DYNAREC_FASTROUND=1
export BOX64_DYNAREC_SAFEFLAGS=1
export BOX64_LD_LIBRARY_PATH="/usr/share/spotify:${BOX64_LD_LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="/usr/share/spotify:${LD_LIBRARY_PATH:-}"
exec box64 /usr/share/spotify/spotify "$@"
