#!/usr/bin/env bash
# vibebuddy-forward.sh <source>
#
# The single fail-open forwarder for every command-hook CLI. Reads the CLI's hook
# event JSON on stdin and POSTs it verbatim to the local vibebuddy daemon at
# /hook?agent=<source>. One forwarder replaces the per-CLI inline curl scripts;
# the daemon's source-aware HookDecoder picks the right decoder from <source>.
#
# `vibebuddy-forward.sh claude` is a drop-in for the original inline curl
# (?agent=claude is normalized identically to no agent param). Never blocks the
# CLI: any failure is swallowed and we always exit 0.
#
# Usage (in a CLI's command hook):
#   .../vibebuddy-forward.sh grok      # positional source
#   .../vibebuddy-forward.sh --source grok   # also accepted
SOURCE="${1:-claude}"
[ "$SOURCE" = "--source" ] && SOURCE="${2:-claude}"

PORT="${VIBEBUDDY_PORT:-9876}"

# Fire-and-forget: discard the response body (-o /dev/null) so a blocking hook
# (e.g. Grok PreToolUse) never mistakes our stdout for an allow/deny decision.
curl -sS --max-time 3 -o /dev/null -X POST --data-binary @- \
  "http://127.0.0.1:${PORT}/hook?agent=${SOURCE}" 2>/dev/null || true
exit 0
