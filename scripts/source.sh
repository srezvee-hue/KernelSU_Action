#!/usr/bin/env bash
# Fetch the kernel source tree.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKSPACE=${WORKSPACE:?WORKSPACE must be set}
KERNEL_DIR="${WORKSPACE}/android-kernel"

# Hard reset the kernel tree before clone so stale generated files or partial
# backports from previous runs cannot leak into a fresh build.
reset_kernel_tree() {
  local dir=$1
  if [ -d "${dir}/.git" ]; then
    info "resetting existing kernel tree at ${dir}"
    git -C "${dir}" reset --hard HEAD >/dev/null 2>&1 || true
    git -C "${dir}" clean -fdx >/dev/null 2>&1 || true
    git -C "${dir}" submodule foreach --recursive 'git reset --hard HEAD >/dev/null 2>&1 || true; git clean -fdx >/dev/null 2>&1 || true' >/dev/null 2>&1 || true
  fi
  rm -rf "${dir}/out" "${dir}/.config" "${dir}/.tmp_versions" "${dir}/include/generated" "${dir}/arch/${ARCH:-arm64}/boot"
}

# Remove any stale clone/build artifacts from previous attempts in the same
# workspace before pulling a fresh source tree.
reset_kernel_tree "${KERNEL_DIR}"
rm -rf "${KERNEL_DIR}"
rm -rf "${WORKSPACE}/out" "${WORKSPACE}/defconfig.orig"

group "Cloning kernel source"
info "${KERNEL_SOURCE} @ ${KERNEL_SOURCE_BRANCH}"

ref_exists "$KERNEL_SOURCE" "$KERNEL_SOURCE_BRANCH" \
	|| die "branch/tag '${KERNEL_SOURCE_BRANCH}' does not exist in ${KERNEL_SOURCE}"

# Use a full clone for kernel sources. Shallow clones can mask inconsistent
# history, partial backports, and submodule state, which are exactly the kinds of
# issues that cause scheduler/arch symbol mismatches during compilation.
retry 3 git clone -q --recursive \
	-b "$KERNEL_SOURCE_BRANCH" "$KERNEL_SOURCE" "$KERNEL_DIR" \
	|| die "failed to clone ${KERNEL_SOURCE}"

# Print the exact tree state before building so we can catch inconsistent source
# trees immediately in CI logs instead of only seeing downstream compiler errors.
info "kernel tree diagnostics"
info "branch: $(git -C "${KERNEL_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
info "head: $(git -C "${KERNEL_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
info "status:"
(git -C "${KERNEL_DIR}" status --short --branch 2>/dev/null || true)
info "submodules:"
(git -C "${KERNEL_DIR}" submodule status --recursive 2>/dev/null || true)
info "symbol scan (warnings only):"
(git -C "${KERNEL_DIR}" grep -nE 'sched_ravg_window|last_wake_ts|free_areai|cpu_soft_restart' -- . ':(exclude).git' 2>/dev/null || true)

# Neutralize any stale generated build artifacts before building.
(
	cd "${KERNEL_DIR}" && \
	make mrproper >/dev/null 2>&1 || true
)

# KernelSU forks compute their version from the commit count, and several
# read it straight out of the enclosing git repo. A depth-1 clone reports 1
# commit, which produces a nonsense version. Unshallow just enough to count.
if [ -f "${KERNEL_DIR}/.git/shallow" ]; then
	debug "kernel tree is shallow; that is fine for building"
fi

KVER=$(kernel_version "$KERNEL_DIR") \
	|| die "could not read VERSION/PATCHLEVEL from ${KERNEL_DIR}/Makefile -- is this a kernel tree?"
export_env KERNEL_VERSION "$KVER"
export_env KERNEL_DIR "$KERNEL_DIR"
ok "kernel source ready (Linux ${KVER})"
summary "| Kernel | \`${KERNEL_SOURCE##*/}\` @ \`${KERNEL_SOURCE_BRANCH}\` (Linux ${KVER}) |"

# LOCALVERSION is used purely to decorate artifact names.
if is_true "${ADD_LOCALVERSION_TO_FILENAME:-false}" && [ -f "${KERNEL_DIR}/localversion" ]; then
	export_env LOCALVERSION "$(cat "${KERNEL_DIR}/localversion")"
else
	export_env LOCALVERSION ""
fi
endgroup
