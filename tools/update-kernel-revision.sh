#!/bin/bash
# Copyright (C) 2026 Savoir-faire Linux, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Check for a new stable Linux kernel revision and open a pull request on
# meta-seapath bumping LINUX_REVISION_VERSION and SRCREV of the matching
# linux-mainline-rt recipe.
#
# The script is standalone: it clones (or updates) its own meta-seapath
# checkout in a work directory, so it can be run from a cronjob without any
# `repo` workspace.
#
# Example crontab entry (every day at 03:17, quiet unless something happens):
#
#   17 3 * * * GH_TOKEN=ghp_xxx /path/to/update-kernel-revision.sh \
#       --log-file "$HOME/.cache/seapath-kernel-update/cron.log" >/dev/null 2>&1

set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------

KERNEL_GIT="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
UPSTREAM_REPO="${SEAPATH_UPSTREAM_REPO:-seapath/meta-seapath}"
BASE_BRANCH="${SEAPATH_BASE_BRANCH:-wrynose}"
KERNEL_SERIES="${SEAPATH_KERNEL_SERIES:-6.12}"
WORKDIR="${SEAPATH_KERNEL_UPDATE_WORKDIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/seapath-kernel-update}"
FORK_OWNER="${SEAPATH_FORK_OWNER:-}"
PUSH_PROTOCOL="ssh"
BRANCH_NAME=""
GIT_NAME="${SEAPATH_GIT_NAME:-}"
GIT_EMAIL="${SEAPATH_GIT_EMAIL:-}"
LOG_FILE=""
DRY_RUN="false"
CHECK_ONLY="false"
NO_PR="false"
FORCE="false"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Name:  print_usage
# Brief: Print script usage
print_usage()
{
    echo "This script checks for a new stable Linux ${KERNEL_SERIES}.x revision and opens a
pull request on ${UPSTREAM_REPO} to bump the kernel recipe.

./$(basename "${0}") [OPTIONS]

Options:
        (-s|--kernel-series)    <x.y>       Kernel series to track (default: ${KERNEL_SERIES})
        (-b|--base-branch)      <branch>    Branch to update and target (default: ${BASE_BRANCH})
        (-r|--repo)             <owner/rep> Upstream repository (default: ${UPSTREAM_REPO})
        (-w|--workdir)          <path>      Work directory holding the clone
                                            (default: ${WORKDIR})
        (-f|--fork)             <owner>     GitHub owner the topic branch is pushed to
                                            (default: authenticated gh user)
        (--branch)              <name>      Topic branch name
                                            (default: kernel-<series>-update-v<version>)
        (--https)                           Push over HTTPS instead of SSH
        (--git-name)            <name>      git user.name used for the commit
        (--git-email)           <email>     git user.email used for the commit
        (--log-file)            <path>      Append timestamped logs to this file
        (-n|--dry-run)                      Do everything locally, but do not push nor
                                            open the pull request
        (-c|--check-only)                   Only report whether an update is available
        (--no-pr)                           Push the branch but do not open a pull request
        (--force)                           Recreate the branch/PR even if one exists
        (-h|--help)                         Display this help message

Environment:
        GH_TOKEN / GITHUB_TOKEN             Token used by the GitHub CLI (required in cron)
        SEAPATH_UPSTREAM_REPO, SEAPATH_BASE_BRANCH, SEAPATH_KERNEL_SERIES,
        SEAPATH_KERNEL_UPDATE_WORKDIR, SEAPATH_FORK_OWNER, SEAPATH_GIT_NAME,
        SEAPATH_GIT_EMAIL                   Same meaning as the matching options

Exit codes:
        0   Up to date, or pull request created/already open
        1   Error
"
}

# Name:  log
# Brief: Print a timestamped message on stderr and, if set, in the log file
log()
{
    local message
    message="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "${message}" >&2
    if [ -n "${LOG_FILE}" ]; then
        echo "${message}" >> "${LOG_FILE}"
    fi
}

# Name:  die
# Brief: Log an error and exit
die()
{
    log "ERROR: $*"
    exit 1
}

# Name:  require_command
# Brief: Ensure a command is available
require_command()
{
    command -v "${1}" > /dev/null 2>&1 || die "'${1}' is required but not installed"
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "${1}" in
        -s|--kernel-series)
            KERNEL_SERIES="${2:?missing value for ${1}}"
            shift 2
            ;;
        -b|--base-branch)
            BASE_BRANCH="${2:?missing value for ${1}}"
            shift 2
            ;;
        -r|--repo)
            UPSTREAM_REPO="${2:?missing value for ${1}}"
            shift 2
            ;;
        -w|--workdir)
            WORKDIR="${2:?missing value for ${1}}"
            shift 2
            ;;
        -f|--fork)
            FORK_OWNER="${2:?missing value for ${1}}"
            shift 2
            ;;
        --branch)
            BRANCH_NAME="${2:?missing value for ${1}}"
            shift 2
            ;;
        --https)
            PUSH_PROTOCOL="https"
            shift
            ;;
        --git-name)
            GIT_NAME="${2:?missing value for ${1}}"
            shift 2
            ;;
        --git-email)
            GIT_EMAIL="${2:?missing value for ${1}}"
            shift 2
            ;;
        --log-file)
            LOG_FILE="${2:?missing value for ${1}}"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN="true"
            shift
            ;;
        -c|--check-only)
            CHECK_ONLY="true"
            shift
            ;;
        --no-pr)
            NO_PR="true"
            shift
            ;;
        --force)
            FORCE="true"
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            print_usage
            die "unknown argument '${1}'"
            ;;
    esac
done

[[ "${KERNEL_SERIES}" =~ ^[0-9]+\.[0-9]+$ ]] || \
    die "invalid kernel series '${KERNEL_SERIES}', expected something like 6.12"

if [ -n "${LOG_FILE}" ]; then
    mkdir -p "$(dirname "${LOG_FILE}")"
    touch "${LOG_FILE}"
fi

require_command git
if [ "${CHECK_ONLY}" = "false" ] && [ "${NO_PR}" = "false" ] && [ "${DRY_RUN}" = "false" ]; then
    require_command gh
fi

REPO_NAME="${UPSTREAM_REPO##*/}"
CLONE_DIR="${WORKDIR}/${REPO_NAME}"
RECIPE_PATH="recipes-kernel/linux/linux-mainline-rt_${KERNEL_SERIES}.bb"

mkdir -p "${WORKDIR}"

# ----------------------------------------------------------------------------
# Only one instance at a time: a cron run must not race with a previous one
# ----------------------------------------------------------------------------

exec 9> "${WORKDIR}/.lock"
if command -v flock > /dev/null 2>&1; then
    flock -n 9 || die "another instance is already running (${WORKDIR}/.lock)"
fi

# ----------------------------------------------------------------------------
# Refresh the meta-seapath checkout on the base branch
# ----------------------------------------------------------------------------

if [ ! -d "${CLONE_DIR}/.git" ]; then
    log "Cloning https://github.com/${UPSTREAM_REPO} into ${CLONE_DIR}"
    git clone --quiet "https://github.com/${UPSTREAM_REPO}" "${CLONE_DIR}" \
        || die "unable to clone https://github.com/${UPSTREAM_REPO}"
fi

cd "${CLONE_DIR}"

log "Fetching ${BASE_BRANCH} from ${UPSTREAM_REPO}"
git remote set-url origin "https://github.com/${UPSTREAM_REPO}"
git fetch --quiet --prune origin "${BASE_BRANCH}" \
    || die "unable to fetch ${BASE_BRANCH} from ${UPSTREAM_REPO}"

# Start from a pristine base branch, whatever the previous run left behind.
git checkout --quiet --force -B "${BASE_BRANCH}" "origin/${BASE_BRANCH}"
git reset --quiet --hard "origin/${BASE_BRANCH}"
git clean --quiet -fdx

[ -f "${RECIPE_PATH}" ] || die "${RECIPE_PATH} not found on ${BASE_BRANCH}"

# ----------------------------------------------------------------------------
# Current revision packaged by the layer
# ----------------------------------------------------------------------------

current_revision="$(sed -n -E 's/^LINUX_REVISION_VERSION = "([0-9]+)"$/\1/p' "${RECIPE_PATH}")"
current_srcrev="$(sed -n -E 's/^SRCREV = "([0-9a-f]{40})"$/\1/p' "${RECIPE_PATH}")"

[ -n "${current_revision}" ] || die "unable to read LINUX_REVISION_VERSION from ${RECIPE_PATH}"
[ -n "${current_srcrev}" ] || die "unable to read SRCREV from ${RECIPE_PATH}"

log "Layer currently tracks v${KERNEL_SERIES}.${current_revision} (${current_srcrev})"

# ----------------------------------------------------------------------------
# Latest stable revision published on kernel.org
# ----------------------------------------------------------------------------

log "Querying ${KERNEL_GIT} for the latest v${KERNEL_SERIES}.x tag"
remote_tags="$(git ls-remote --tags "${KERNEL_GIT}" "refs/tags/v${KERNEL_SERIES}.*")" \
    || die "unable to list tags from ${KERNEL_GIT}"

series_regex="${KERNEL_SERIES//./\\.}"
latest_revision="$(echo "${remote_tags}" \
    | sed -n -E "s#^[0-9a-f]{40}[[:space:]]+refs/tags/v${series_regex}\.([0-9]+)\$#\1#p" \
    | sort -n \
    | tail -1)"

[ -n "${latest_revision}" ] || die "no v${KERNEL_SERIES}.x tag found on ${KERNEL_GIT}"

latest_version="${KERNEL_SERIES}.${latest_revision}"

# Stable tags are annotated: SRCREV must be the peeled commit, not the tag
# object (this is what the previous bumps used).
latest_srcrev="$(echo "${remote_tags}" \
    | awk -v ref="refs/tags/v${latest_version}^{}" '$2 == ref { print $1 }')"
if [ -z "${latest_srcrev}" ]; then
    latest_srcrev="$(echo "${remote_tags}" \
        | awk -v ref="refs/tags/v${latest_version}" '$2 == ref { print $1 }')"
fi

[[ "${latest_srcrev}" =~ ^[0-9a-f]{40}$ ]] || \
    die "unable to resolve the commit of tag v${latest_version}"

log "Latest stable release is v${latest_version} (${latest_srcrev})"

if [ "${latest_revision}" -le "${current_revision}" ]; then
    log "Kernel ${KERNEL_SERIES} is up to date, nothing to do"
    exit 0
fi

log "Update available: v${KERNEL_SERIES}.${current_revision} -> v${latest_version}"

if [ "${CHECK_ONLY}" = "true" ]; then
    exit 0
fi

# ----------------------------------------------------------------------------
# Where the topic branch is pushed
# ----------------------------------------------------------------------------

if [ -z "${BRANCH_NAME}" ]; then
    BRANCH_NAME="kernel-${KERNEL_SERIES}-update-v${latest_version}"
fi

if [ -z "${FORK_OWNER}" ]; then
    if command -v gh > /dev/null 2>&1; then
        FORK_OWNER="$(gh api user --jq .login 2>/dev/null || true)"
    fi
    [ -n "${FORK_OWNER}" ] || \
        die "unable to determine the fork owner, use --fork or SEAPATH_FORK_OWNER"
fi

if [ "${PUSH_PROTOCOL}" = "ssh" ]; then
    PUSH_URL="git@github.com:${FORK_OWNER}/${REPO_NAME}.git"
else
    PUSH_URL="https://github.com/${FORK_OWNER}/${REPO_NAME}.git"
fi

if [ "${FORK_OWNER}" = "${UPSTREAM_REPO%%/*}" ]; then
    PR_HEAD="${BRANCH_NAME}"
else
    PR_HEAD="${FORK_OWNER}:${BRANCH_NAME}"
fi

# ----------------------------------------------------------------------------
# Skip work already done by a previous run
# ----------------------------------------------------------------------------

if [ "${FORCE}" = "false" ] && command -v gh > /dev/null 2>&1; then
    existing_pr="$(gh pr list --repo "${UPSTREAM_REPO}" --state open \
        --head "${BRANCH_NAME}" --json number,url --jq '.[0].url' 2>/dev/null || true)"
    if [ -n "${existing_pr}" ]; then
        log "A pull request for ${BRANCH_NAME} is already open: ${existing_pr}"
        exit 0
    fi
fi

if [ "${FORCE}" = "false" ] && \
   [ -n "$(git ls-remote --heads "${PUSH_URL}" "${BRANCH_NAME}" 2>/dev/null || true)" ]; then
    log "Branch ${BRANCH_NAME} already exists on ${FORK_OWNER}/${REPO_NAME}, nothing to do"
    exit 0
fi

# ----------------------------------------------------------------------------
# Bump the recipe
# ----------------------------------------------------------------------------

log "Creating branch ${BRANCH_NAME}"
git checkout --quiet -B "${BRANCH_NAME}" "origin/${BASE_BRANCH}"

sed -i -E "s#^LINUX_REVISION_VERSION = \"[0-9]+\"\$#LINUX_REVISION_VERSION = \"${latest_revision}\"#" \
    "${RECIPE_PATH}"
sed -i -E "s#^SRCREV = \"[0-9a-f]{40}\"\$#SRCREV = \"${latest_srcrev}\"#" \
    "${RECIPE_PATH}"

grep -q "^LINUX_REVISION_VERSION = \"${latest_revision}\"\$" "${RECIPE_PATH}" \
    || die "LINUX_REVISION_VERSION was not updated in ${RECIPE_PATH}"
grep -q "^SRCREV = \"${latest_srcrev}\"\$" "${RECIPE_PATH}" \
    || die "SRCREV was not updated in ${RECIPE_PATH}"

# The bump must touch that single recipe, and nothing else.
changed_files="$(git diff --name-only)"
if [ "${changed_files}" != "${RECIPE_PATH}" ]; then
    git checkout --quiet -- . || true
    die "unexpected changes in the working tree: ${changed_files:-none}"
fi

[ "$(git diff --numstat -- "${RECIPE_PATH}" | cut -f1)" = "2" ] || \
    die "expected exactly 2 modified lines in ${RECIPE_PATH}"

# ----------------------------------------------------------------------------
# Commit
# ----------------------------------------------------------------------------

if [ -n "${GIT_NAME}" ]; then
    git config user.name "${GIT_NAME}"
fi
if [ -n "${GIT_EMAIL}" ]; then
    git config user.email "${GIT_EMAIL}"
fi

git config user.name > /dev/null 2>&1 || \
    die "git user.name is not set, use --git-name (cron has no user git config)"
git config user.email > /dev/null 2>&1 || \
    die "git user.email is not set, use --git-email"

commit_subject="recipes-kernel/linux: update kernel ${KERNEL_SERIES} to v${latest_version}"
commit_body="Bumps LINUX_REVISION_VERSION and SRCREV in $(basename "${RECIPE_PATH}") to
track the latest stable kernel ${KERNEL_SERIES} release (v${latest_version})."

git add "${RECIPE_PATH}"
git commit --quiet --signoff --message "${commit_subject}" --message "${commit_body}"

log "Committed: ${commit_subject}"

if [ "${DRY_RUN}" = "true" ]; then
    log "Dry run: branch ${BRANCH_NAME} left in ${CLONE_DIR}, nothing pushed"
    git --no-pager show --stat --oneline HEAD >&2
    exit 0
fi

# ----------------------------------------------------------------------------
# Push and open the pull request
# ----------------------------------------------------------------------------

log "Pushing ${BRANCH_NAME} to ${PUSH_URL}"
git push --quiet --force-with-lease "${PUSH_URL}" "${BRANCH_NAME}" \
    || die "unable to push ${BRANCH_NAME} to ${PUSH_URL}"

if [ "${NO_PR}" = "true" ]; then
    log "Branch pushed, pull request creation skipped (--no-pr)"
    exit 0
fi

changelog_url="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_SERIES%%.*}.x/ChangeLog-${latest_version}"
pr_body="$(cat <<EOF
Update the ${KERNEL_SERIES} RT kernel from \`v${KERNEL_SERIES}.${current_revision}\` to \`v${latest_version}\`.

| | Before | After |
| --- | --- | --- |
| \`LINUX_REVISION_VERSION\` | \`${current_revision}\` | \`${latest_revision}\` |
| \`SRCREV\` | \`${current_srcrev}\` | \`${latest_srcrev}\` |

\`SRCREV\` is the commit pointed to by the annotated tag \`v${latest_version}\` of
[linux-stable](${KERNEL_GIT}).

Upstream changelog: ${changelog_url}

---
Opened automatically by \`tools/update-kernel-revision.sh\`.
EOF
)"

log "Opening pull request against ${UPSTREAM_REPO}:${BASE_BRANCH}"
pr_url="$(gh pr create \
    --repo "${UPSTREAM_REPO}" \
    --base "${BASE_BRANCH}" \
    --head "${PR_HEAD}" \
    --title "${commit_subject}" \
    --body "${pr_body}")" \
    || die "unable to create the pull request"

log "Pull request created: ${pr_url}"
