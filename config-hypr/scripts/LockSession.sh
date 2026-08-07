#!/usr/bin/env bash
# ==================================================
#  Race-free hyprlock launcher (called by hypridle's lock_cmd)
# ==================================================
# `pidof hyprlock || hyprlock` is not atomic: when several lock requests
# arrive in the same instant they all pass the pidof check before any
# hyprlock has registered, so several launch and only one wins the
# ext-session-lock-v1 protocol. The losers linger and make pidof succeed
# forever, which silently blocks every later lock.
#
# flock holds the lock for as long as hyprlock lives and releases it
# automatically when hyprlock exits or is killed, so no stale state.

exec flock -n "${XDG_RUNTIME_DIR:-/tmp}/hyprlock.lock" hyprlock -q
