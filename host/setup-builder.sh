#!/bin/sh
# Create (or remove) a dedicated, locked-down host account that runs a
# rootless Podman API socket for lucoa's bundled podman-remote client.
#
# Run on the container HOST as root (for example with sudo). It never runs
# inside lucoa, and nothing it creates is baked into the image.
#
#   sudo sh host/setup-builder.sh --client HOSTUSER [options]
#   sudo sh host/setup-builder.sh --uninstall [--delete-user] [options]
#
# What it sets up (see README "Dedicated builder account"):
#   - an account (default lucoa-builder) with no login shell, a locked
#     password, a private 0700 home, no privileged groups and no sudo rights;
#   - subordinate UID/GID ranges so it can run rootless Podman;
#   - root-owned cgroup limits on its user slice (memory, tasks, CPU/IO weight)
#     covering the API service and every container it starts;
#   - a root-owned socket directory (default /run/lucoa-builder) that only the
#     builder account and the named --client accounts/UIDs can traverse;
#   - a socket-activated rootless `podman system service` in the builder's user
#     manager, with lingering so it runs without a login. The socket is 0600 and
#     shared with clients through a POSIX ACL.
#
# Anyone who can reach the socket controls the builder account (they can run
# containers and bind-mount anything it can read). The account is the sandbox:
# keep nothing else in it.
set -eu

PROG=${0##*/}
MARKER='lucoa container builder'
UNIT=lucoa-builder-podman

builder=lucoa-builder
socket_dir=/run/lucoa-builder
clients=
memory_max=50%
tasks_max=4096
cpu_weight=50
io_weight=50
cpu_quota=
mode=install
reuse_user=0
want_id=
MIN_ID=6000
delete_user=0
dry_run=0

usage() {
    cat <<EOF
Usage: $PROG --client USER|UID [--client ...] [options]
       $PROG --uninstall [--delete-user] [--user NAME] [--socket-dir DIR]

Install options:
  --client USER|UID   Host account (or numeric host UID) allowed to use the
                      socket. Required; repeatable. Use the account that runs
                      lucoa with --userns=keep-id:uid=1000,gid=1000, or the
                      host UID that lucoa's node user (UID 1000) maps to.
  --user NAME         Builder account name (default: $builder).
  --socket-dir DIR    Socket directory under /run (default: $socket_dir).
  --memory-max VALUE  MemoryMax for the builder slice, e.g. 8G or 50%
                      (default: $memory_max; 'infinity' disables).
  --tasks-max N       TasksMax for the builder slice (default: $tasks_max).
  --cpu-weight N      CPUWeight 1-10000 (default: $cpu_weight; normal is 100).
  --io-weight N       IOWeight 1-10000 (default: $io_weight; normal is 100).
  --cpu-quota PCT     Optional hard CPU cap, e.g. 200% for two CPUs.
  --uid N             UID and GID for a new account (default: the smallest
                      number >= $MIN_ID free as both UID and GID).
  --reuse-user        Adopt an existing account not created by this script.
                      It is hardened (nologin shell, locked password) and
                      refused if it is privileged.

Uninstall options:
  --uninstall         Stop the socket and remove the units, limits, socket
                      directory and lingering. The account and its images stay.
  --delete-user       With --uninstall: also delete the account, its home
                      (all images, containers and volumes) and subuid ranges.

Common:
  --dry-run           Print actions without changing anything.
  -h, --help          Show this help.
EOF
}

say() { printf '%s\n' "$*"; }
note() { printf '==> %s\n' "$*"; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

run() {
    if [ "$dry_run" = 1 ]; then
        printf '+ %s\n' "$*"
    else
        "$@"
    fi
}

# write_file PATH MODE: install stdin as PATH (root-owned) with MODE.
write_file() {
    if [ "$dry_run" = 1 ]; then
        printf '+ write %s (mode %s):\n' "$1" "$2"
        sed 's/^/    /'
        return
    fi
    tmp=$(mktemp "$1.XXXXXX")
    cat > "$tmp"
    chmod "$2" "$tmp"
    mv -f "$tmp" "$1"
}

need_value() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
    case $1 in
        --client) need_value "$@"; clients="$clients $2"; shift 2 ;;
        --user) need_value "$@"; builder=$2; shift 2 ;;
        --socket-dir) need_value "$@"; socket_dir=$2; shift 2 ;;
        --memory-max) need_value "$@"; memory_max=$2; shift 2 ;;
        --tasks-max) need_value "$@"; tasks_max=$2; shift 2 ;;
        --cpu-weight) need_value "$@"; cpu_weight=$2; shift 2 ;;
        --io-weight) need_value "$@"; io_weight=$2; shift 2 ;;
        --cpu-quota) need_value "$@"; cpu_quota=$2; shift 2 ;;
        --uid) need_value "$@"; want_id=$2; shift 2 ;;
        --reuse-user) reuse_user=1; shift ;;
        --uninstall) mode=uninstall; shift ;;
        --delete-user) delete_user=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

# ---- validation -------------------------------------------------------------

matches() { printf '%s\n' "$1" | grep -Eqx "$2"; }

name_re='[a-z_][a-z0-9_-]{0,30}'
matches "$builder" "$name_re" || die "invalid --user name: $builder"
matches "$socket_dir" '/run/[A-Za-z0-9._-]+' \
    || die "--socket-dir must be a single directory directly under /run: $socket_dir"
case $socket_dir in /run/user|/run/podman|/run/systemd|/run/containers) die "refusing reserved directory $socket_dir" ;; esac

if [ "$mode" = install ]; then
    [ -n "$clients" ] || { usage >&2; die '--client is required'; }
    [ "$delete_user" = 0 ] || die '--delete-user is only valid with --uninstall'
    matches "$memory_max" '[0-9]+[KMGT]?|[0-9]{1,2}%|100%|infinity' || die "invalid --memory-max: $memory_max"
    matches "$tasks_max" '[0-9]+|infinity' || die "invalid --tasks-max: $tasks_max"
    for w in "$cpu_weight" "$io_weight"; do
        matches "$w" '[0-9]+' && [ "$w" -ge 1 ] && [ "$w" -le 10000 ] || die "weights must be 1-10000: $w"
    done
    if [ -n "$want_id" ]; then
        matches "$want_id" '[0-9]+' && [ "$want_id" -ge 1000 ] && [ "$want_id" -lt 60000 ] \
            || die "--uid must be a number from 1000 to 59999: $want_id"
    fi
    [ -z "$cpu_quota" ] || matches "$cpu_quota" '[1-9][0-9]*%' || die "invalid --cpu-quota: $cpu_quota"
fi

[ "$(id -u)" = 0 ] || [ "$dry_run" = 1 ] || die 'run as root on the host (for example: sudo sh host/setup-builder.sh ...)'
[ -d /run/systemd/system ] || die 'systemd is required (no /run/systemd/system)'
for tool in systemctl loginctl systemd-tmpfiles getent; do
    command -v "$tool" >/dev/null || die "$tool not found"
done

# ---- helpers ----------------------------------------------------------------

user_exists() { getent passwd "$1" >/dev/null; }
passwd_field() { getent passwd "$1" | cut -d: -f"$2"; }

uid_of() { passwd_field "$builder" 3; }

id_free() { ! getent passwd "$1" >/dev/null && ! getent group "$1" >/dev/null; }

# Smallest number >= MIN_ID that is unused as both a UID and a GID.
first_free_id() {
    n=$MIN_ID
    until id_free "$n"; do
        n=$((n + 1))
        [ "$n" -lt 60000 ] || die "no free UID/GID between $MIN_ID and 59999"
    done
    printf '%s\n' "$n"
}

wait_user_manager() {
    [ "$dry_run" = 1 ] && return
    i=0
    until systemctl is-active --quiet "user@$1.service" && [ -S "/run/user/$1/bus" ]; do
        i=$((i + 1))
        [ "$i" -lt 50 ] || die "user manager user@$1.service or its D-Bus socket did not start (Debian/Ubuntu: install dbus-user-session)"
        sleep 0.2
    done
}

user_ctl() { run systemctl --user -M "$builder@" "$@"; }

# Highest end of any subordinate range in /etc/subuid and /etc/subgid.
next_subid_start() {
    cat /etc/subuid /etc/subgid 2>/dev/null | awk -F: '
        NF >= 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { e = $2 + $3; if (e > max) max = e }
        END { if (max < 100000) max = 100000; print max }'
}

has_subid() { awk -F: -v u="$1" -v id="$2" '$1 == u || $1 == id { f = 1 } END { exit !f }' "$3" 2>/dev/null; }

privileged_groups='root wheel sudo admin adm docker podman lxd libvirt kvm disk shadow systemd-journal'

check_unprivileged() {
    [ "$(passwd_field "$builder" 3)" != 0 ] || die "$builder has UID 0"
    [ "$(passwd_field "$builder" 4)" != 0 ] || die "$builder has primary GID 0"
    for g in $(id -nG "$builder"); do
        for p in $privileged_groups; do
            [ "$g" != "$p" ] || die "$builder is in privileged group '$g'; remove it first"
        done
    done
    if command -v sudo >/dev/null; then
        if sudo -n -l -U "$builder" 2>/dev/null | grep -q 'may run the following'; then
            die "$builder has sudo rules; remove them first"
        fi
    fi
}

nologin_shell() {
    for s in /usr/sbin/nologin /sbin/nologin /usr/bin/false /bin/false; do
        [ -x "$s" ] && { printf '%s\n' "$s"; return; }
    done
    die 'no nologin shell found'
}

# ---- uninstall --------------------------------------------------------------

if [ "$mode" = uninstall ]; then
    if user_exists "$builder"; then
        uid=$(uid_of)
        if [ "$(passwd_field "$builder" 5)" != "$MARKER" ] && [ "$delete_user" = 1 ]; then
            die "$builder was not created by this script; refusing --delete-user"
        fi
        if systemctl is-active --quiet "user@$uid.service"; then
            note "Stopping $UNIT socket for $builder"
            user_ctl disable --now "$UNIT.socket" "$UNIT.service" || true
        fi
        note "Disabling lingering for $builder"
        run loginctl disable-linger "$builder" || true
        run rm -f "/etc/systemd/system/user-$uid.slice.d/50-lucoa-builder.conf"
        run rmdir "/etc/systemd/system/user-$uid.slice.d" 2>/dev/null || true
    else
        uid=
        warn "account $builder does not exist"
    fi
    note 'Removing units, tmpfiles entry and socket directory'
    run rm -f "/etc/systemd/user/$UNIT.socket" "/etc/systemd/user/$UNIT.service" /etc/tmpfiles.d/lucoa-builder.conf
    run rm -rf "$socket_dir"
    run systemctl daemon-reload
    if [ "$delete_user" = 1 ] && [ -n "$uid" ]; then
        note "Deleting $builder, its home, images, containers and volumes"
        run loginctl terminate-user "$builder" 2>/dev/null || true
        run systemctl stop "user@$uid.service" || true
        for f in /etc/subuid /etc/subgid; do
            if [ "$dry_run" = 1 ]; then
                say "+ remove $builder ranges from $f"
            elif [ -f "$f" ]; then
                tmp=$(mktemp "$f.XXXXXX")
                awk -F: -v u="$builder" -v id="$uid" '$1 != u && $1 != id' "$f" > "$tmp"
                chmod --reference="$f" "$tmp" 2>/dev/null || chmod 644 "$tmp"
                mv -f "$tmp" "$f"
            fi
        done
        run userdel -r "$builder"
    fi
    note 'Uninstall complete. Remove the socket mount from lucoa before restarting it.'
    exit 0
fi

# ---- install ----------------------------------------------------------------

for tool in podman setfacl getfacl groupadd useradd usermod runuser; do
    command -v "$tool" >/dev/null || die "$tool not found (install podman and acl)"
done
podman_bin=$(command -v podman)
setfacl_bin=$(command -v setfacl)

# 1. Account.
shell=$(nologin_shell)
if user_exists "$builder"; then
    if [ -n "$want_id" ] && [ "$(passwd_field "$builder" 3)" != "$want_id" ]; then
        warn "$builder already exists with UID $(passwd_field "$builder" 3); --uid is ignored (accounts are never renumbered)"
    fi
    if [ "$(passwd_field "$builder" 5)" = "$MARKER" ]; then
        note "Account $builder exists (created by this script)"
    elif [ "$reuse_user" = 1 ]; then
        note "Adopting existing account $builder (--reuse-user)"
    else
        die "account $builder already exists and was not created by this script; pass --reuse-user to adopt and harden it, or choose another --user"
    fi
else
    if [ -n "$want_id" ]; then
        id_free "$want_id" || die "UID/GID $want_id is already in use"
        new_id=$want_id
    else
        new_id=$(first_free_id)
    fi
    getent group "$builder" >/dev/null && die "group $builder already exists; remove it or choose another --user"
    note "Creating account $builder (UID/GID $new_id)"
    run groupadd --gid "$new_id" "$builder"
    run useradd --create-home --uid "$new_id" --gid "$new_id" --shell "$shell" --comment "$MARKER" "$builder"
fi
if [ "$dry_run" = 1 ] && ! user_exists "$builder"; then
    uid=$new_id; home="/home/$builder"
else
    check_unprivileged
    uid=$(uid_of)
    home=$(passwd_field "$builder" 6)
fi
note "Hardening $builder: nologin shell, locked password, private home"
run usermod --shell "$shell" --lock "$builder"
run chmod 0700 "$home"

# 2. Clients: resolve to numeric host UIDs; never root or the builder itself.
acl_clients=
client_names=
for c in $clients; do
    if matches "$c" '[0-9]+'; then
        cuid=$c
    elif matches "$c" "$name_re" && user_exists "$c"; then
        cuid=$(passwd_field "$c" 3)
        client_names="$client_names $c"
    else
        die "--client $c is not an existing account or numeric UID"
    fi
    [ "$cuid" != 0 ] || die '--client must not be root'
    [ "$c" != "$builder" ] && [ "$cuid" != "$uid" ] || die '--client must differ from the builder account'
    acl_clients="$acl_clients $cuid"
done

# 3. Subordinate IDs for rootless Podman.
for f in /etc/subuid /etc/subgid; do [ -e "$f" ] || run touch "$f"; done
if has_subid "$builder" "$uid" /etc/subuid && has_subid "$builder" "$uid" /etc/subgid; then
    note "Subordinate ID ranges already present for $builder"
else
    start=$(next_subid_start)
    end=$((start + 65535))
    note "Allocating subordinate IDs $start-$end"
    has_subid "$builder" "$uid" /etc/subuid || run usermod --add-subuids "$start-$end" "$builder"
    has_subid "$builder" "$uid" /etc/subgid || run usermod --add-subgids "$start-$end" "$builder"
fi

# 4. Root-owned resource limits on the builder's user slice.
note "Applying slice limits: MemoryMax=$memory_max TasksMax=$tasks_max CPUWeight=$cpu_weight IOWeight=$io_weight${cpu_quota:+ CPUQuota=$cpu_quota}"
slice_dir="/etc/systemd/system/user-$uid.slice.d"
run mkdir -p "$slice_dir"
{
    say "# Generated by lucoa host/setup-builder.sh for $builder. Root-owned:"
    say '# applies to the Podman API service and every container it starts.'
    say '[Slice]'
    say "MemoryMax=$memory_max"
    [ "$memory_max" = infinity ] || say 'MemorySwapMax=0'
    say "TasksMax=$tasks_max"
    say "CPUWeight=$cpu_weight"
    say "IOWeight=$io_weight"
    [ -z "$cpu_quota" ] || say "CPUQuota=$cpu_quota"
} | write_file "$slice_dir/50-lucoa-builder.conf" 0644

# 5. Root-owned socket directory, traversable only by builder and clients.
acl="u:$builder:rwx"
for cuid in $acl_clients; do acl="$acl,u:$cuid:--x"; done
note "Configuring $socket_dir (root-owned, ACL: $acl)"
{
    say '# Generated by lucoa host/setup-builder.sh. Recreated at every boot.'
    say "d $socket_dir 0700 root root -"
    say "a $socket_dir - - - - $acl"
} | write_file /etc/tmpfiles.d/lucoa-builder.conf 0644
run systemd-tmpfiles --create /etc/tmpfiles.d/lucoa-builder.conf

# 6. Socket-activated rootless Podman API in the builder's user manager.
sock="$socket_dir/podman.sock"
post=
for cuid in $acl_clients; do post="$post
ExecStartPost=$setfacl_bin -m u:$cuid:rw $sock"; done
note "Installing user units $UNIT.socket/.service"
write_file "/etc/systemd/user/$UNIT.socket" 0644 <<EOF
# Generated by lucoa host/setup-builder.sh. Do not edit; rerun the script.
[Unit]
Description=Rootless Podman API socket for lucoa
ConditionUser=$builder

[Socket]
ListenStream=$sock
SocketMode=0600
RemoveOnStop=yes$post

[Install]
WantedBy=sockets.target
EOF
write_file "/etc/systemd/user/$UNIT.service" 0644 <<EOF
# Generated by lucoa host/setup-builder.sh. Do not edit; rerun the script.
[Unit]
Description=Rootless Podman API service for lucoa
Requires=$UNIT.socket
After=$UNIT.socket
ConditionUser=$builder

[Service]
Type=exec
KillMode=process
Delegate=yes
Environment=LOGGING=--log-level=info
ExecStart=$podman_bin \$LOGGING system service
EOF

run systemctl daemon-reload
note "Enabling lingering for $builder (user manager runs without a login)"
run loginctl enable-linger "$builder"
run systemctl start "user@$uid.service"
wait_user_manager "$uid"
user_ctl daemon-reload
# Restart picks up changed client ACLs on reruns.
user_ctl enable "$UNIT.socket"
user_ctl restart "$UNIT.socket"

# 7. Verify.
if [ "$dry_run" = 1 ]; then
    note 'Dry run: skipped verification'
else
    note 'Verifying'
    [ -S "$sock" ] || die "socket $sock was not created"
    getfacl -p "$sock" 2>/dev/null | grep -q '^user::rw-$' || die "unexpected owner mode on $sock"
    getfacl -p "$sock" 2>/dev/null | grep -q '^other::---$' || die "socket $sock is accessible to others"
    if setpriv --version >/dev/null 2>&1 && ! printf ' %s ' "$acl_clients" | grep -q ' 65534 '; then
        if setpriv --reuid=65534 --regid=65534 --clear-groups test -x "$socket_dir"; then
            die "$socket_dir is traversable by an unrelated user"
        fi
        say "    ok: unrelated users cannot reach $socket_dir"
    fi
    for c in $client_names; do
        chome=$(passwd_field "$c" 6)
        if out=$(cd / && runuser -u "$c" -- env -i HOME="$chome" PATH=/usr/bin:/bin \
                "$podman_bin" --remote --url "unix://$sock" info --format '{{.Host.Security.Rootless}}' 2>&1) \
            && [ "$out" = true ]; then
            say "    ok: $c reaches a rootless Podman API through $sock"
        else
            die "client $c could not use $sock: $out"
        fi
    done
fi

cat <<EOF

Done. Builder account: $builder (UID $uid). Socket: $sock

Mount it into lucoa (run by a --client account) by adding to \`podman run\`:

  --userns=keep-id:uid=1000,gid=1000 \\
  --security-opt label=disable \\
  -v $socket_dir:/run/podman \\

or to a Quadlet [Container] section:

  UserNS=keep-id:uid=1000,gid=1000
  SecurityLabelDisable=true
  Volume=$socket_dir:/run/podman

Do not add :Z/:z to this mount. Inside lucoa, check with:
  podman info --format '{{.Host.Security.Rootless}}'   # expect: true

Builds and containers run as $builder on the host, inside its slice limits.
Images, containers and volumes use disk in $home (not limited by the slice);
prune them from inside lucoa with: podman system prune --all
EOF
