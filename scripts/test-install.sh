#!/usr/bin/env bash
# Run from anywhere:
#   ./scripts/test-install.sh
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
INSTALL_SH="$SCRIPT_DIR/install.sh"
PASSES=0
FAILURES=0

if [[ ! -f "$INSTALL_SH" ]]; then
  echo "FAIL  $INSTALL_SH does not exist"
  exit 1
fi

abspath() {
  local path="$1"
  if [[ -d "$path" ]]; then
    (CDPATH= cd -- "$path" && pwd -P)
    return
  fi
  local dir base
  dir=$(CDPATH= cd -- "$(dirname "$path")" && pwd -P)
  base=$(basename "$path")
  printf '%s/%s\n' "$dir" "$base"
}

resolve_link() {
  local link="$1" raw
  raw=$(readlink "$link") || return 1
  if [[ "$raw" == /* ]]; then
    abspath "$raw"
  else
    abspath "$(dirname "$link")/$raw"
  fi
}

assert_true() {
  local message="$2"
  if [[ "$1" -eq 1 ]]; then
    PASSES=$((PASSES + 1))
    echo "  ok  $message"
  else
    FAILURES=$((FAILURES + 1))
    echo "  FAIL  $message"
  fi
}

paths_equal() {
  [[ "$(abspath "$1")" == "$(abspath "$2")" ]]
}

new_fixture() {
  local root catalog
  root=$(mktemp -d "${TMPDIR:-/tmp}/skills-install-test.XXXXXX")
  catalog="$root/repo"
  mkdir -p "$catalog/skills/hello" "$catalog/skills/world" "$catalog/skills/not-a-skill" "$catalog/scripts" "$root/home"
  printf '%s\n' '---' 'name: hello' 'description: test' '---' > "$catalog/skills/hello/SKILL.md"
  printf '%s\n' '---' 'name: world' 'description: test' '---' > "$catalog/skills/world/SKILL.md"
  printf '%s\n' 'ignore me' > "$catalog/skills/not-a-skill/README.md"
  cp "$INSTALL_SH" "$catalog/scripts/install.sh"
  cp "$SCRIPT_DIR/install.ps1" "$catalog/scripts/install.ps1"
  chmod +x "$catalog/scripts/install.sh"
  FIXTURE_ROOT="$root"
  FIXTURE_CATALOG="$catalog"
  FIXTURE_HOME="$root/home"
  FIXTURE_INSTALL="$catalog/scripts/install.sh"
}

run_install() {
  "$FIXTURE_INSTALL" --repo-root "$FIXTURE_CATALOG" --user-home "$FIXTURE_HOME" "$@"
}

cleanup() {
  rm -rf "$FIXTURE_ROOT"
}

echo 'project install'
new_fixture
run_install --project
hello=$(abspath "$FIXTURE_CATALOG/skills/hello")
world=$(abspath "$FIXTURE_CATALOG/skills/world")
for root in .agents/skills .claude/skills; do
  if [[ -L "$FIXTURE_CATALOG/$root/hello" ]] && paths_equal "$(resolve_link "$FIXTURE_CATALOG/$root/hello")" "$hello"; then
    assert_true 1 "$root/hello -> skills/hello"
  else
    assert_true 0 "$root/hello -> skills/hello"
  fi
  if [[ -L "$FIXTURE_CATALOG/$root/world" ]] && paths_equal "$(resolve_link "$FIXTURE_CATALOG/$root/world")" "$world"; then
    assert_true 1 "$root/world -> skills/world"
  else
    assert_true 0 "$root/world -> skills/world"
  fi
  if [[ ! -e "$FIXTURE_CATALOG/$root/not-a-skill" ]]; then
    assert_true 1 "$root does not link folders without SKILL.md"
  else
    assert_true 0 "$root does not link folders without SKILL.md"
  fi
done
if [[ ! -e "$FIXTURE_HOME/.agents/skills/hello" ]]; then
  assert_true 1 'project-only does not write user home'
else
  assert_true 0 'project-only does not write user home'
fi
cleanup

echo 'global install'
new_fixture
run_install --global
hello=$(abspath "$FIXTURE_CATALOG/skills/hello")
if [[ -L "$FIXTURE_HOME/.agents/skills/hello" ]] && paths_equal "$(resolve_link "$FIXTURE_HOME/.agents/skills/hello")" "$hello"; then
  assert_true 1 'global ~/.agents/skills/hello'
else
  assert_true 0 'global ~/.agents/skills/hello'
fi
if [[ -L "$FIXTURE_HOME/.claude/skills/hello" ]] && paths_equal "$(resolve_link "$FIXTURE_HOME/.claude/skills/hello")" "$hello"; then
  assert_true 1 'global ~/.claude/skills/hello'
else
  assert_true 0 'global ~/.claude/skills/hello'
fi
if [[ ! -e "$FIXTURE_CATALOG/.agents/skills/hello" ]]; then
  assert_true 1 'global-only does not write the repo'
else
  assert_true 0 'global-only does not write the repo'
fi
cleanup

echo 'default scope is project and global'
new_fixture
run_install
hello=$(abspath "$FIXTURE_CATALOG/skills/hello")
if [[ -L "$FIXTURE_CATALOG/.claude/skills/hello" ]] && paths_equal "$(resolve_link "$FIXTURE_CATALOG/.claude/skills/hello")" "$hello"; then
  assert_true 1 'default links project'
else
  assert_true 0 'default links project'
fi
if [[ -L "$FIXTURE_HOME/.claude/skills/hello" ]] && paths_equal "$(resolve_link "$FIXTURE_HOME/.claude/skills/hello")" "$hello"; then
  assert_true 1 'default links global'
else
  assert_true 0 'default links global'
fi
cleanup

echo 'idempotent re-run'
new_fixture
run_install --project
run_install --project
hello=$(abspath "$FIXTURE_CATALOG/skills/hello")
if [[ -L "$FIXTURE_CATALOG/.agents/skills/hello" ]] && paths_equal "$(resolve_link "$FIXTURE_CATALOG/.agents/skills/hello")" "$hello"; then
  assert_true 1 'second run keeps the same link'
else
  assert_true 0 'second run keeps the same link'
fi
cleanup

echo 'refuse to clobber a real directory'
new_fixture
mkdir -p "$FIXTURE_CATALOG/.claude/skills/hello"
printf '%s\n' 'do not delete' > "$FIXTURE_CATALOG/.claude/skills/hello/keep.txt"
run_install --project
if [[ -f "$FIXTURE_CATALOG/.claude/skills/hello/keep.txt" ]]; then
  assert_true 1 'real directory contents survive'
else
  assert_true 0 'real directory contents survive'
fi
if [[ ! -L "$FIXTURE_CATALOG/.claude/skills/hello" ]]; then
  assert_true 1 'real directory was not replaced with a link'
else
  assert_true 0 'real directory was not replaced with a link'
fi
cleanup

echo 'uninstall is scoped to this catalog'
new_fixture
run_install --global
mkdir -p "$FIXTURE_ROOT/other-skill"
ln -s "$FIXTURE_ROOT/other-skill" "$FIXTURE_HOME/.claude/skills/foreign"
run_install --global --uninstall
if [[ ! -e "$FIXTURE_HOME/.claude/skills/hello" ]]; then
  assert_true 1 'uninstall removes our global hello link'
else
  assert_true 0 'uninstall removes our global hello link'
fi
if [[ -L "$FIXTURE_HOME/.claude/skills/foreign" ]]; then
  assert_true 1 'uninstall leaves links that point elsewhere'
else
  assert_true 0 'uninstall leaves links that point elsewhere'
fi
cleanup

echo 'prune stale links'
new_fixture
run_install --project
rm -rf "$FIXTURE_CATALOG/skills/hello"
run_install --project
if [[ ! -e "$FIXTURE_CATALOG/.agents/skills/hello" ]]; then
  assert_true 1 'stale hello link is removed'
else
  assert_true 0 'stale hello link is removed'
fi
if [[ -L "$FIXTURE_CATALOG/.agents/skills/world" ]]; then
  assert_true 1 'world link remains'
else
  assert_true 0 'world link remains'
fi
cleanup

echo 'dry-run'
new_fixture
run_install --project --dry-run
if [[ ! -e "$FIXTURE_CATALOG/.agents/skills/hello" ]]; then
  assert_true 1 'dry-run does not create links'
else
  assert_true 0 'dry-run does not create links'
fi
cleanup

echo
echo "$PASSES passed, $FAILURES failed"
if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi
exit 0
