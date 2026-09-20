#!/usr/bin/env bash
# Link skills/ into agent discovery dirs without copying files.
#
#   ./scripts/install.sh                 # this repo + user home
#   ./scripts/install.sh --project       # this repo only
#   ./scripts/install.sh --global        # user home only
#   ./scripts/install.sh --uninstall
#   ./scripts/install.sh --dry-run
#   ./scripts/install.sh --status
#
# On Windows this execs install.ps1 (junctions). On macOS/Linux, symlinks.

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
DISCOVERY_NAMES=".agents .claude"

is_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

show_help() {
  cat <<'EOF'
Link skills/ into agent discovery directories. Author skills only under skills/<name>/SKILL.md.

  install.sh                 this repo and user home
  install.sh --project       this repo only (.agents/skills, .claude/skills)
  install.sh --global        user home only (~/.agents/skills, ~/.claude/skills)
  install.sh --uninstall     remove this catalog's links (same scope flags)
  install.sh --dry-run       print actions, change nothing
  install.sh --status        show where each skill is linked

  --repo-root PATH           catalog root (default: parent of scripts/)
  --user-home PATH           home for global links (default: $HOME)

Links are symlinks on macOS/Linux. On Windows, install.sh runs install.ps1
and uses directory junctions. Existing real directories are left alone.
Links that point at other catalogs are left alone.
EOF
}

if is_windows; then
  mapped=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) mapped+=(-Project); shift ;;
      --global) mapped+=(-Global); shift ;;
      --uninstall) mapped+=(-Uninstall); shift ;;
      --dry-run) mapped+=(-DryRun); shift ;;
      --status) mapped+=(-Status); shift ;;
      --help|-h) mapped+=(-Help); shift ;;
      --repo-root)
        if [[ $# -lt 2 ]]; then
          echo "install.sh: --repo-root needs a path" >&2
          exit 2
        fi
        mapped+=(-RepoRoot "$2"); shift 2 ;;
      --user-home)
        if [[ $# -lt 2 ]]; then
          echo "install.sh: --user-home needs a path" >&2
          exit 2
        fi
        mapped+=(-UserHome "$2"); shift 2 ;;
      *)
        echo "install.sh: unknown argument: $1" >&2
        exit 2 ;;
    esac
  done
  if command -v pwsh >/dev/null 2>&1; then
    exec pwsh -NoProfile -File "$SCRIPT_DIR/install.ps1" "${mapped[@]}"
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    exec powershell.exe -NoProfile -File "$SCRIPT_DIR/install.ps1" "${mapped[@]}"
  fi
  echo "On Windows run: pwsh -File scripts/install.ps1" >&2
  exit 1
fi

PROJECT=0
GLOBAL=0
UNINSTALL=0
DRY_RUN=0
STATUS=0
REPO_ROOT=""
USER_HOME_OPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT=1; shift ;;
    --global) GLOBAL=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --status) STATUS=1; shift ;;
    --help|-h) show_help; exit 0 ;;
    --repo-root)
      if [[ $# -lt 2 ]]; then
        echo "install.sh: --repo-root needs a path" >&2
        exit 2
      fi
      REPO_ROOT="$2"; shift 2 ;;
    --user-home)
      if [[ $# -lt 2 ]]; then
        echo "install.sh: --user-home needs a path" >&2
        exit 2
      fi
      USER_HOME_OPT="$2"; shift 2 ;;
    *)
      echo "install.sh: unknown argument: $1" >&2
      exit 2 ;;
  esac
done

abspath() {
  local path="$1"
  local dir base parent
  if [[ -d "$path" && ! -L "$path" ]]; then
    (CDPATH= cd -- "$path" && pwd -P)
    return
  fi
  parent=$(dirname "$path")
  base=$(basename "$path")
  if [[ -d "$parent" ]]; then
    dir=$(CDPATH= cd -- "$parent" && pwd -P)
    printf '%s/%s\n' "$dir" "$base"
    return
  fi
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$(pwd)" "$path"
  fi
}

same_path() {
  [[ "$(abspath "$1")" == "$(abspath "$2")" ]]
}

is_under() {
  local path parent
  path=$(abspath "$1")
  parent=$(abspath "$2")
  [[ "$path" == "$parent" || "$path" == "$parent"/* ]]
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

rel_from_catalog() {
  local path="$1" catalog="$2"
  local path_abs catalog_abs
  path_abs=$(abspath "$path")
  catalog_abs=$(abspath "$catalog")
  if [[ "$path_abs" == "$catalog_abs"/* ]]; then
    printf '%s\n' "${path_abs#"$catalog_abs"/}"
  else
    printf '%s\n' "$path_abs"
  fi
}

write_action() {
  local verb="$1" link="$2" target="$3"
  printf '%-8s %s -> %s\n' "$verb" "$(rel_from_catalog "$link" "$REPO_ROOT")" "$(rel_from_catalog "$target" "$REPO_ROOT")"
}

if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT=$(abspath "$SCRIPT_DIR/..")
else
  REPO_ROOT=$(abspath "$REPO_ROOT")
fi

if [[ -n "$USER_HOME_OPT" ]]; then
  USER_HOME="$USER_HOME_OPT"
elif [[ -z "${HOME:-}" ]]; then
  echo "install.sh: HOME is not set" >&2
  exit 1
fi
USER_HOME=$(abspath "$USER_HOME")

DO_PROJECT=1
DO_GLOBAL=1
if [[ "$PROJECT" -eq 1 && "$GLOBAL" -eq 0 ]]; then
  DO_GLOBAL=0
fi
if [[ "$GLOBAL" -eq 1 && "$PROJECT" -eq 0 ]]; then
  DO_PROJECT=0
fi

SKILLS_ROOT="$REPO_ROOT/skills"

list_skills() {
  local dir name
  if [[ ! -d "$SKILLS_ROOT" ]]; then
    return
  fi
  for dir in "$SKILLS_ROOT"/*/; do
    [[ -d "$dir" ]] || continue
    name=$(basename "$dir")
    if [[ -f "$dir/SKILL.md" ]]; then
      printf '%s\n' "$name"
    fi
  done
}

discovery_roots() {
  local base="$1" name
  for name in $DISCOVERY_NAMES; do
    printf '%s/%s/skills\n' "$base" "$name"
  done
}

install_link() {
  local link="$1" target="$2" current
  if [[ -L "$link" ]]; then
    current=$(resolve_link "$link")
    if same_path "$current" "$target"; then
      write_action "ok" "$link" "$target"
      return
    fi
    if ! is_under "$current" "$SKILLS_ROOT"; then
      echo "skip     $link (points at another catalog)"
      return
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      write_action "would" "$link" "$target"
      return
    fi
    rm -f "$link"
  elif [[ -e "$link" ]]; then
    echo "skip     $link (real directory, not replaced)"
    return
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    write_action "would" "$link" "$target"
    return
  fi
  mkdir -p "$(dirname "$link")"
  ln -sfn "$target" "$link"
  write_action "link" "$link" "$target"
}

remove_our_link() {
  local link="$1" current
  if [[ ! -L "$link" ]]; then
    return
  fi
  current=$(resolve_link "$link") || return 0
  if ! is_under "$current" "$SKILLS_ROOT"; then
    return
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    write_action "would-rm" "$link" "$current"
    return
  fi
  rm -f "$link"
  write_action "unlink" "$link" "$current"
}

prune_root() {
  local root="$1" child name current keep existing
  [[ -d "$root" ]] || return 0
  for child in "$root"/*; do
    [[ -e "$child" || -L "$child" ]] || continue
    name=$(basename "$child")
    if [[ "$name" == "README.md" ]]; then
      continue
    fi
    if [[ ! -L "$child" ]]; then
      continue
    fi
    current=$(resolve_link "$child") || continue
    if ! is_under "$current" "$SKILLS_ROOT"; then
      continue
    fi
    keep=0
    for existing in ${SKILL_NAMES[@]+"${SKILL_NAMES[@]}"}; do
      if [[ "$existing" == "$name" ]]; then
        keep=1
        break
      fi
    done
    if [[ "$keep" -eq 1 ]]; then
      continue
    fi
    remove_our_link "$child"
  done
}

show_status() {
  local name root link current
  if [[ ${#SKILL_NAMES[@]} -eq 0 ]]; then
    echo "No skills in $SKILLS_ROOT"
    return
  fi
  for name in ${SKILL_NAMES[@]+"${SKILL_NAMES[@]}"}; do
    echo "$name"
    for root in ${ROOTS[@]+"${ROOTS[@]}"}; do
      link="$root/$name"
      if [[ -L "$link" ]]; then
        current=$(resolve_link "$link")
        if same_path "$current" "$SKILLS_ROOT/$name"; then
          echo "  linked  $link"
          continue
        fi
      fi
      echo "  missing $link"
    done
  done
}

SKILL_NAMES=()
while IFS= read -r name; do
  SKILL_NAMES+=("$name")
done < <(list_skills)

ROOTS=()
if [[ "$DO_PROJECT" -eq 1 ]]; then
  while IFS= read -r r; do ROOTS+=("$r"); done < <(discovery_roots "$REPO_ROOT")
fi
if [[ "$DO_GLOBAL" -eq 1 ]]; then
  while IFS= read -r r; do ROOTS+=("$r"); done < <(discovery_roots "$USER_HOME")
fi

if [[ "$STATUS" -eq 1 ]]; then
  show_status
  exit 0
fi

if [[ "$UNINSTALL" -eq 1 ]]; then
  for root in ${ROOTS[@]+"${ROOTS[@]}"}; do
    [[ -d "$root" ]] || continue
    for child in "$root"/*; do
      [[ -e "$child" || -L "$child" ]] || continue
      if [[ "$(basename "$child")" == "README.md" ]]; then
        continue
      fi
      remove_our_link "$child"
    done
  done
  exit 0
fi

if [[ ${#SKILL_NAMES[@]} -eq 0 ]]; then
  echo "No skills found in $SKILLS_ROOT (need skills/<name>/SKILL.md)"
fi

for root in ${ROOTS[@]+"${ROOTS[@]}"}; do
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$root"
  fi
  for name in ${SKILL_NAMES[@]+"${SKILL_NAMES[@]}"}; do
    install_link "$root/$name" "$SKILLS_ROOT/$name"
  done
  prune_root "$root"
done
