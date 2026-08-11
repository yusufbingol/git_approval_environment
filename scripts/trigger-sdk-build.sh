#!/usr/bin/env bash
# trigger-sdk-build.sh — gh CLI wrapper for the "SDK Build Trigger" workflow.
#
# Reads the current VERSION_NAME / VERSION_CODE from gradle.properties on the
# target branch, proposes bumped values, shows a "current -> new" confirmation,
# then dispatches .github/workflows/sdk-build-trigger.yml via `gh workflow run`.
#
# The workflow itself is untouched: its validations and the GitHub Environment
# approval gates (sdk-publish, version-mismatch-confirmation) still apply.
#
# Requirements: gh (authenticated via `gh auth login`), git, base64.
#
# Usage:
#   scripts/trigger-sdk-build.sh [options]
#
# Options:
#   --branch <name>           Branch to run the workflow on (default: current branch)
#   --publish                 Enable publish (goes through the sdk-publish approval gate)
#   --internal-only           Internal-only publish (requires --publish and --suffix)
#   --suffix <s>              INTERNAL_VERSION_SUFFIX, e.g. rc.1 (requires --internal-only)
#   --version-name <X.Y.Z-N>  Override the proposed VERSION_NAME
#   --version-code <N>        Override the proposed VERSION_CODE
#   --no-update-version       Trigger without updating the version (skips version inputs)
#   --yes                     Skip the local confirmation prompt
#   -h, --help                Show this help

set -euo pipefail

REPO="yusufbingol/git_approval_environment"
WORKFLOW="sdk-build-trigger.yml"
VERSION_FILE="gradle.properties"

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

branch=""
publish=false
internal_only=false
suffix=""
override_name=""
override_code=""
update_version=true
assume_yes=false

while [ $# -gt 0 ]; do
  case "$1" in
    --branch)            branch="$2"; shift 2 ;;
    --publish)           publish=true; shift ;;
    --internal-only)     internal_only=true; shift ;;
    --suffix)            suffix="$2"; shift 2 ;;
    --version-name)      override_name="$2"; shift 2 ;;
    --version-code)      override_code="$2"; shift 2 ;;
    --no-update-version) update_version=false; shift ;;
    --yes)               assume_yes=true; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "Error: gh CLI is not installed." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Error: gh is not authenticated. Run 'gh auth login'." >&2; exit 1; }

if [ -z "$branch" ]; then
  branch="$(git rev-parse --abbrev-ref HEAD)"
fi

# Local pre-checks mirroring the workflow's validation, to fail fast.
if [ "$internal_only" = true ] && [ "$publish" != true ]; then
  echo "Error: --internal-only requires --publish." >&2; exit 2
fi
if [ "$internal_only" = true ] && [ -z "$suffix" ]; then
  echo "Error: --internal-only requires --suffix (e.g. --suffix rc.1)." >&2; exit 2
fi
if [ -n "$suffix" ] && [ "$internal_only" != true ]; then
  echo "Error: --suffix is only allowed with --internal-only." >&2; exit 2
fi

version_name=""
version_code=""
current_name="(unknown)"
current_code="(unknown)"

if [ "$update_version" = true ]; then
  # 1) Read the current version from the target branch (remote, not local
  #    checkout, so values match what the workflow branch actually contains).
  if ! props="$(gh api "repos/${REPO}/contents/${VERSION_FILE}?ref=${branch}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)" || [ -z "$props" ]; then
    echo "Error: could not read ${VERSION_FILE} on branch '${branch}' of ${REPO}." >&2
    echo "Hint: push the branch first, or pass --no-update-version." >&2
    exit 1
  fi
  current_name="$(sed -n 's/^VERSION_NAME=//p' <<<"$props" | tr -d '[:space:]')"
  current_code="$(sed -n 's/^VERSION_CODE=//p' <<<"$props" | tr -d '[:space:]')"
  if [ -z "$current_name" ] || [ -z "$current_code" ]; then
    echo "Error: VERSION_NAME/VERSION_CODE not found in ${VERSION_FILE} on '${branch}'." >&2
    exit 1
  fi

  # 2) Propose bumped values (build number +1, code +1) unless overridden.
  if [ -n "$override_name" ]; then
    version_name="$override_name"
  else
    ver="${current_name%-*}"
    build="${current_name##*-}"
    version_name="${ver}-$((build + 1))"
  fi
  if [ -n "$override_code" ]; then
    version_code="$override_code"
  else
    version_code="$((current_code + 1))"
  fi
fi

# 3) Show the summary and confirm.
echo "Repo            : ${REPO}"
echo "Workflow        : ${WORKFLOW}"
echo "Branch          : ${branch}"
echo "publish         : ${publish}"
echo "internal_only   : ${internal_only}"
[ -n "$suffix" ] && echo "suffix          : ${suffix}"
echo "update_version  : ${update_version}"
if [ "$update_version" = true ]; then
  echo "VERSION_NAME    : current ${current_name}  ->  ${version_name}"
  echo "VERSION_CODE    : current ${current_code}  ->  ${version_code}"
fi

if [ "$assume_yes" != true ]; then
  read -rp "Bu değerlerle tetiklensin mi? [y/N] " answer
  [[ "${answer:-}" == [yY] ]] || { echo "İptal edildi."; exit 1; }
fi

# 4) Dispatch the workflow.
args=(
  -f "publish=${publish}"
  -f "update_version=${update_version}"
  -f "internal_only=${internal_only}"
)
if [ "$update_version" = true ]; then
  args+=(-f "version_name=${version_name}" -f "version_code=${version_code}")
fi
if [ -n "$suffix" ]; then
  args+=(-f "internal_version_suffix=${suffix}")
fi

gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$branch" "${args[@]}"

echo ""
echo "Tetiklendi. Takip için:"
echo "  gh run list  --repo ${REPO} --workflow=${WORKFLOW} -L1"
echo "  gh run watch --repo ${REPO}"
