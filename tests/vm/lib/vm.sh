#!/usr/bin/env bash
# VM lifecycle and exec helpers for machinekit end-to-end tests.
# Source this file — it sets VM_NAME, VM_OS, and exposes helper functions.
#
# Two ways to run commands in the VM:
#
#   vm::exec CMD [ARGS...]
#     Run a command without a shell intermediary. Good for simple commands
#     (true, mkdir, mount) where you don't need $HOME, pipes, or expansion.
#     On Linux uses tart exec (execve, no shell). On macOS/SSH each argument
#     is shell-quoted so it survives SSH's arg-joining.
#
#   vm::shell  (reads script from stdin)
#     Run a bash script piped via stdin. Use with a heredoc:
#
#       vm::shell <<'SCRIPT'    # quoted: no host expansion; $vars expand in VM
#       test -f ~/.gitconfig
#       SCRIPT
#
#       mk_path="$(vm::machinekit_path)"
#       vm::shell <<SCRIPT      # unquoted: $mk_path is expanded by the host
#       MK_PATH='$mk_path'
#       "\$MK_PATH/bin/foo"     # \$ → $ in the remote script
#       SCRIPT
#
# Linux VMs (ghcr.io/cirruslabs/ubuntu): tart exec (guest agent present).
# macOS VMs (macos-*-vanilla):           SSH with admin/admin credentials.

VM_NAME=""
VM_OS=""

_VM_SSH_USER="admin"
_VM_SSH_PASS="admin"
_VM_DIR_TAG="mk"
_VM_LINUX_MOUNT="/mnt/mk-host"
_VM_MAC_MOUNT="/Volumes/My Shared Files"

# When set to a file path, vm::exec and vm::shell route all output there.
# The run script sets this before each scenario and dumps it on failure.
_VM_LOG=""

# _vm_out CMD [ARGS...]
# Run CMD, sending its stdout+stderr to $_VM_LOG when active, or through
# to the terminal otherwise.
_vm_out() {
  if [ -n "$_VM_LOG" ]; then
    "$@" >> "$_VM_LOG" 2>&1
  else
    "$@"
  fi
}

# vm::start IMAGE REPO_DIR
# Clone IMAGE to a temp VM, start it headlessly with REPO_DIR mounted
# read-only via virtiofs, and wait until the VM accepts commands.
vm::start() {
  local image="$1" repo_dir="$2"
  VM_NAME="mk-test-$(date +%s)"
  VM_OS="$(vm::_detect_os "$image")"

  vm_log "Cloning $image → $VM_NAME"
  tart clone "$image" "$VM_NAME"

  vm_log "Starting VM (machinekit at $(vm::machinekit_path))"
  tart run "$VM_NAME" --no-graphics --dir="${_VM_DIR_TAG}:${repo_dir}:ro" &

  vm_log "Waiting for VM to be ready"
  vm::wait_ready

  vm_step "Configuring passwordless sudo"
  # machinekit apply requires sudo in non-interactive mode. Both Cirrus images
  # use 'admin' as the admin password; configure a sudoers drop-in so the test
  # run doesn't need pre-warmed credentials.
  vm::shell <<'SCRIPT'
if ! sudo -n true 2>/dev/null; then
  echo 'admin' | sudo -S bash -c \
    'echo "admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/mk-test && chmod 440 /etc/sudoers.d/mk-test'
fi
SCRIPT

  if [ "$VM_OS" = "linux" ]; then
    vm_step "Mounting virtiofs share"
    vm::exec sudo mkdir -p "$_VM_LINUX_MOUNT"
    vm::exec sudo mount -t virtiofs com.apple.virtio-fs.automount "$_VM_LINUX_MOUNT"
  fi
}

# vm::exec CMD [ARGS...]
vm::exec() {
  if [ "$VM_OS" = "linux" ]; then
    # tart exec passes args directly to execve — no shell, no quoting needed.
    _vm_out tart exec "$VM_NAME" "$@"
  else
    local ip remote_cmd
    ip="$(tart ip "$VM_NAME" 2>/dev/null)" || return 1
    # SSH joins args with spaces before handing to the remote shell, so we
    # must quote each one ourselves to survive that round-trip.
    remote_cmd="$(printf '%q ' "$@")"
    _vm_out sshpass -p "$_VM_SSH_PASS" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=5 \
      "${_VM_SSH_USER}@${ip}" "$remote_cmd"
  fi
}

# vm::shell  (stdin → bash in the VM)
# When a log file is active, uses bash -xs so the full command trace is
# captured and available on failure. Otherwise plain -s.
vm::shell() {
  local bash_flags="-s"
  [ -n "$_VM_LOG" ] && bash_flags="-xs"
  if [ "$VM_OS" = "linux" ]; then
    _vm_out tart exec -i "$VM_NAME" bash "$bash_flags"
  else
    local ip
    ip="$(tart ip "$VM_NAME" 2>/dev/null)" || return 1
    _vm_out sshpass -p "$_VM_SSH_PASS" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=5 \
      "${_VM_SSH_USER}@${ip}" "bash $bash_flags"
  fi
}

# vm::wait_ready
# Poll until the VM accepts commands (max ~3 minutes).
vm::wait_ready() {
  local i=0
  while [ "$i" -lt 60 ]; do
    if vm::_probe 2>/dev/null; then return 0; fi
    sleep 3
    i=$((i + 1))
  done
  printf 'error: VM %s did not become ready after 3 minutes\n' "$VM_NAME" >&2
  return 1
}

# vm::_probe — silent readiness check, no [exec] output.
vm::_probe() {
  if [ "$VM_OS" = "linux" ]; then
    tart exec "$VM_NAME" true 2>/dev/null
  else
    local ip
    ip="$(tart ip "$VM_NAME" 2>/dev/null)" || return 1
    sshpass -p "$_VM_SSH_PASS" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=5 \
      "${_VM_SSH_USER}@${ip}" true 2>/dev/null
  fi
}

# vm::machinekit_path
# Path inside the VM where the machinekit repo is mounted.
vm::machinekit_path() {
  if [ "$VM_OS" = "linux" ]; then
    printf '%s/%s' "$_VM_LINUX_MOUNT" "$_VM_DIR_TAG"
  else
    printf '%s/%s' "$_VM_MAC_MOUNT" "$_VM_DIR_TAG"
  fi
}

# vm::stop
# Stop and delete the current VM. Safe to call when VM_NAME is empty.
vm::stop() {
  [ -z "${VM_NAME:-}" ] && return 0
  local name="$VM_NAME"
  VM_NAME=""
  vm_log "Stopping $name"
  tart stop "$name" 2>/dev/null || true
  tart delete "$name" 2>/dev/null || true
}

vm::_detect_os() {
  case "$1" in
    *ubuntu*|*linux*|*debian*) printf 'linux' ;;
    *) printf 'darwin' ;;
  esac
}
