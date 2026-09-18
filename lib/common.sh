#!/bin/bash
# lib/common.sh - shared helpers for setup-ubuntu.sh / setup-macos.sh.
# Sourced, never executed. ASCII only. Works on bash 3.2+ (macOS) and bash 4+.
# shellcheck disable=SC2148

ASSUME_YES="${ASSUME_YES:-0}"

log()  { echo "[..] $*"; }
ok()   { echo "[ok] $*"; }
warn() { echo "[!!] $*" >&2; }
die()  { echo "[!!] $*" >&2; exit 1; }

# need_cmd <bin> [hint]
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1${2:+ ($2)}"
}

# confirm <prompt> — honors ASSUME_YES=1 (returns 0 without asking).
# Returns 0 on yes, 1 on no.
confirm() {
    if [ "$ASSUME_YES" = 1 ]; then
        log "confirmed (non-interactive): $1"
        return 0
    fi
    local ans=""
    read -r -p "[??] $1 [y/N] " ans || return 1
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

# secret_prompt <prompt> <varname> — silent read into named var (never echoed).
secret_prompt() {
    local _val=""
    read -r -s -p "[??] $1: " _val || die "input aborted"
    echo ""
    printf -v "$2" '%s' "$_val"
    unset _val
}
