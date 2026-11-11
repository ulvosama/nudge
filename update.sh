#!/bin/zsh
# Nudge self-update, run by the app (src/Update.swift) from the source folder it was built from.
#
#   update.sh check <installed-commit>
#       Fetch origin/main, fast-forward if the folder is clean, and if the result differs from the
#       installed app: build, run both test suites, and print "READY <commit>". Otherwise prints
#       "UPTODATE <commit>" or "SKIP <reason>". Never touches /Applications.
#   update.sh install <nudge-pid>
#       Wait for that Nudge to quit, copy build/Nudge.app to /Applications, register it, relaunch.
set -u
cd "$(dirname "$0")" || exit 1
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

case "${1:-}" in
check)
  installed="${2:-}"
  git rev-parse --git-dir >/dev/null 2>&1 || { echo "SKIP not a git folder"; exit 0; }
  if ! git fetch -q origin main 2>/dev/null; then
    echo "SKIP couldn't reach origin"; exit 0
  fi
  if [ -n "$(git status --porcelain)" ]; then
    # Someone is editing here; their work wins. Updates resume once it's committed.
    echo "SKIP uncommitted changes in $(pwd)"; exit 0
  fi
  head=$(git rev-parse HEAD); remote=$(git rev-parse origin/main)
  if [ "$head" != "$remote" ]; then
    if git merge-base --is-ancestor HEAD origin/main; then
      git merge -q --ff-only origin/main || { echo "SKIP fast-forward failed"; exit 0; }
    elif ! git merge-base --is-ancestor origin/main HEAD; then
      echo "SKIP this folder and GitHub have diverged; merge by hand"; exit 0
    fi   # else: local commits not pushed yet; build them
  fi
  short=$(git rev-parse --short HEAD)
  if [ "$short" = "$installed" ]; then echo "UPTODATE $short"; exit 0; fi

  rm -f build/.tested
  ./build.sh >/dev/null 2>&1 || { echo "FAIL build failed at $short"; exit 1; }
  python3 tests/helper_tests.py >/dev/null 2>&1 || { echo "FAIL Suite A failed at $short"; exit 1; }
  t=$(mktemp -d)
  swiftc -swift-version 5 -parse-as-library -D SNAPSHOT -target "$(uname -m)-apple-macos14.0" \
    src/Shared.swift src/Theme.swift src/Matrix.swift src/Export.swift src/Update.swift src/Welcome.swift src/App.swift \
    tests/StoreTests.swift -o "$t/storetests" >/dev/null 2>&1 && "$t/storetests" >/dev/null 2>&1
  ok=$?; rm -rf "$t"
  [ $ok -eq 0 ] || { echo "FAIL Suite B failed at $short"; exit 1; }
  codesign -v build/Nudge.app 2>/dev/null || { echo "FAIL signature check failed at $short"; exit 1; }
  echo "$short" > build/.tested   # install only copies this exact, tested build
  echo "READY $short"
  ;;
install)
  pid="${2:-}"
  [ -d build/Nudge.app ] && [ -f build/.tested ] || exit 1
  built=$(/usr/libexec/PlistBuddy -c "Print :NudgeCommit" build/Nudge.app/Contents/Info.plist 2>/dev/null)
  [ "$built" = "$(cat build/.tested)" ] || exit 1   # rebuilt by hand since the tests ran
  # Wait (up to 30 s) for the running Nudge to hand back its questions and quit.
  for _ in $(seq 1 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  pkill -x Nudge 2>/dev/null; sleep 0.3
  ditto build/Nudge.app /Applications/Nudge.app && "$LSREG" -f /Applications/Nudge.app
  open /Applications/Nudge.app
  ;;
*)
  echo "usage: update.sh check <installed-commit> | install <nudge-pid>"; exit 2
  ;;
esac
