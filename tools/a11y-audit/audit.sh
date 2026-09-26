#!/bin/zsh
# Apple's accessibility audit over the demo build, one screen at a time.
#   tools/a11y-audit/audit.sh phone|watch <out-dir> [content-size-category]
# e.g. tools/a11y-audit/audit.sh phone .scratch/a11y/phone-ax5 UICTContentSizeCategoryAccessibilityXXXL
#
# Needs: the app already installed on the simulator named by A11Y_PHONE_UDID /
# A11Y_WATCH_UDID (booted, demo data needs nothing else). Writes issues.jsonl (one
# JSON object per audit issue, or {"type":"CLEAN"}), tree.txt (the element tree)
# and one PNG per screen. Screens: PAGES (phone, VIBEBUDDY_DEMO_PAGE values, "home"
# = none) and SCREENS (watch, scenario:page[:task]).
set -eu
here=${0:A:h}
kind=$1; out=${2:A}; size=${3:-}
derived=${A11Y_DERIVED_DATA:-$here/.build}
mkdir -p $out; rm -f $out/issues.jsonl $out/tree.txt
[[ -d $here/A11yAudit.xcodeproj ]] || (cd $here && xcodegen generate >/dev/null)
if [[ $kind == phone ]]; then
  dest="id=${A11Y_PHONE_UDID:?set A11Y_PHONE_UDID}"; scheme=AXAuditUITests
  export TEST_RUNNER_AX_PAGES="${PAGES:-home,list,read,usage,customize,newtask,voice}"
else
  dest="id=${A11Y_WATCH_UDID:?set A11Y_WATCH_UDID}"; scheme=AXWAuditUITests
  export TEST_RUNNER_AX_SCREENS="${SCREENS:-normal:home,permission:home,question:home,normal:quota,staleQuota:quota,normal:home:demo-watch-tests,macDisconnected:home}"
fi
export TEST_RUNNER_AX_OUT=$out TEST_RUNNER_AX_SIZE=$size
xcodebuild test -project $here/A11yAudit.xcodeproj -scheme $scheme -destination "$dest" \
  -derivedDataPath $derived > $out/xcb.log 2>&1 || true
grep -E "Test Suite 'All tests' (passed|failed)|error:" $out/xcb.log | head -3
python3 - $out/issues.jsonl <<'PY'
import json, sys, collections
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
issues = [r for r in rows if r['type'] != 'CLEAN']
print(len(issues), 'issues')
for (s, t), n in sorted(collections.Counter((r['screen'], r['type']) for r in issues).items()):
    print(f'  {s:28} {t:14} {n}')
PY
