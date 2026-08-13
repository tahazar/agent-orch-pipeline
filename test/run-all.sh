#!/bin/bash
# run-all.sh - the whole orch suite.
#
# No Claude session, no network, no tmux, no API key. Every suite builds its
# own throwaway repo and its own task-list root, so nothing here touches
# ~/.claude and nothing is left behind.
#
#   bash test/run-all.sh

set -u
HERE="$(cd -P "$(dirname "$0")" && pwd)"

SUITES="agent-lint substrate gates health tier findings candidates report endtoend"
FAILED=''
START="$(date -u +%s)"

for s in $SUITES; do
  printf '\n═══ %s ═══\n\n' "$s"
  if [ "$s" = "agent-lint" ]; then
    bash "$HERE/$s.sh" || FAILED="$FAILED $s"
  else
    bash "$HERE/$s.test.sh" || FAILED="$FAILED $s"
  fi
done

printf '\n═══ summary ═══\n\n'
if [ -n "$FAILED" ]; then
  printf 'FAILED:%s\n' "$FAILED"
  exit 1
fi
printf 'all suites passed in %ss\n' "$(( $(date -u +%s) - START ))"
