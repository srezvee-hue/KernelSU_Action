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

# Full clone is mandatory here: shallow history can mask inconsistent or
# partially backported tree state, which is exactly what produces a kernel API
# mismatch during compilation.
retry 3 git clone -q --recursive \
	-b "$KERNEL_SOURCE_BRANCH" "$KERNEL_SOURCE" "$KERNEL_DIR" \
	|| die "failed to clone ${KERNEL_SOURCE}"

# Fail fast if the kernel tree is not pristine. This prevents us from wasting CI
# time compiling a tree that has been modified, partially patched, or carries an
# unexpected submodule state.
info "kernel tree diagnostics"
info "branch: $(git -C "${KERNEL_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
info "head: $(git -C "${KERNEL_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
info "status:"
(git -C "${KERNEL_DIR}" status --short --branch 2>/dev/null || true)
info "submodules:"
(git -C "${KERNEL_DIR}" submodule status --recursive 2>/dev/null || true)
info "warning-only symbol scan:"
(git -C "${KERNEL_DIR}" grep -nE 'sched_ravg_window|last_wake_ts|free_areai|cpu_soft_restart' -- . ':(exclude).git' 2>/dev/null || true)

# A clean build must start from a pristine source tree. If the checkout is dirty,
# abort before make to avoid the classic scheduler/zone API mismatches seen in
# mixed or stale trees.
if [ -n "$(git -C "${KERNEL_DIR}" status --porcelain 2>/dev/null)" ]; then
  die "kernel tree is dirty after checkout; refusing to build a mixed tree. Clean the source tree and retry."
fi

# Neutralize stale generated build artifacts before the actual compile step.
(
  cd "${KERNEL_DIR}" && \
  make mrproper >/dev/null 2>&1 || true
)

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
