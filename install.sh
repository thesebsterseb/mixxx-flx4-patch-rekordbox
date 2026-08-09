#!/usr/bin/env bash
#
# mixxx-pi-tune -- reapply Mixxx + Raspberry Pi tuning on a fresh image.
#
#   sudo ./install.sh
#
# Safe to run repeatedly; every step is idempotent.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- which unprivileged user are we tuning for? ------------------------------
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(logname 2>/dev/null || echo pi)}}"
if [[ "$TARGET_USER" == "root" ]]; then
    TARGET_USER="pi"
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "$TARGET_HOME" ]]; then
    echo "!! no such user: $TARGET_USER (override with TARGET_USER=... sudo -E ./install.sh)" >&2
    exit 1
fi

# Mixxx's settings dir. 2.3 and 2.4 use ~/.mixxx; prefer whichever already
# exists so this keeps working if a future version moves to XDG paths.
if [[ -z "${MIXXX_DIR:-}" ]]; then
    for d in "$TARGET_HOME/.mixxx" "$TARGET_HOME/.local/share/mixxx"; do
        [[ -d "$d" ]] && { MIXXX_DIR="$d"; break; }
    done
fi
MIXXX_DIR="${MIXXX_DIR:-$TARGET_HOME/.mixxx}"
CONTROLLER_DIR="$MIXXX_DIR/controllers"

# Name of the stock mapping to extend. Override if you switch controllers:
#   MAPPING_MATCH='DDJ-400' sudo -E ./install.sh
MAPPING_MATCH="${MAPPING_MATCH:-FLX4}"
MAPPING_SUFFIX="rekordbox-patch"
MAPPING_LABEL="(rekordbox patch)"
OVERRIDE_JS="Pioneer-DDJ-FLX4-rekordbox-patch.js"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   \033[33m!! %s\033[0m\n' "$*"; }

if [[ $EUID -ne 0 ]]; then
    echo "run me with sudo" >&2
    exit 1
fi

say "Tuning for user: $TARGET_USER  (home: $TARGET_HOME, settings: $MIXXX_DIR)"

# --- 1. CPU governor ---------------------------------------------------------
# Driven through sysfs by our own tiny unit rather than cpufrequtils: that
# package was dropped from Debian after bullseye and is absent on trixie /
# Raspberry Pi OS trixie.
say "CPU governor -> performance"
CPU0_CPUFREQ=/sys/devices/system/cpu/cpu0/cpufreq
if [[ ! -e "$CPU0_CPUFREQ/scaling_governor" ]]; then
    warn "kernel exposes no cpufreq interface -- skipping governor step"
elif ! grep -qw performance "$CPU0_CPUFREQ/scaling_available_governors"; then
    warn "driver offers only: $(cat "$CPU0_CPUFREQ/scaling_available_governors") -- skipping"
else
    install -m 0755 "$REPO_DIR/system/mixxx-cpu-governor" /usr/local/sbin/mixxx-cpu-governor
    install -m 0644 "$REPO_DIR/system/mixxx-cpu-governor.service" \
        /etc/systemd/system/mixxx-cpu-governor.service
    systemctl daemon-reload
    # Warn rather than abort: the mapping step below is the important one.
    systemctl enable --now mixxx-cpu-governor.service \
        || warn "could not enable mixxx-cpu-governor.service -- check systemctl status"
    # Raspberry Pi OS ships an 'ondemand' init script that sets ondemand a
    # minute into boot; older images run cpufrequtils. Present on some images,
    # absent on others -- don't fail either way.
    systemctl disable ondemand 2>/dev/null || true
    # If cpufrequtils happens to be installed (older Pi images), keep its
    # default in sync so it can't fight us at boot.
    if [[ -f /etc/default/cpufrequtils ]]; then
        echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
        info "also set GOVERNOR in /etc/default/cpufrequtils"
    fi
    info "now: $(cat "$CPU0_CPUFREQ/scaling_governor") (persists via mixxx-cpu-governor.service)"
fi

# --- 2. audio group ----------------------------------------------------------
say "Group membership"
if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx audio; then
    info "$TARGET_USER already in 'audio'"
else
    usermod -aG audio "$TARGET_USER"
    info "added $TARGET_USER to 'audio' (takes effect at next login)"
fi

# --- 3. realtime limits ------------------------------------------------------
say "Realtime limits"
install -m 0644 "$REPO_DIR/system/99-audio.conf" /etc/security/limits.d/99-audio.conf
info "installed /etc/security/limits.d/99-audio.conf"

# --- 4. mapping override -----------------------------------------------------
say "Mixxx mapping override"

# Locate Mixxx's shipped controller mappings.
if [[ -z "${SYS_CONTROLLERS:-}" ]]; then
    for d in /usr/share/mixxx/controllers /usr/local/share/mixxx/controllers \
             /opt/mixxx/share/mixxx/controllers; do
        [[ -d "$d" ]] && { SYS_CONTROLLERS="$d"; break; }
    done
fi
if [[ -z "${SYS_CONTROLLERS:-}" ]]; then
    warn "no system controller dir found -- skipping mapping step"
    warn "(override with SYS_CONTROLLERS=... sudo -E ./install.sh)"
else
    info "system mappings: $SYS_CONTROLLERS"
    SRC_XML="$(find "$SYS_CONTROLLERS" -maxdepth 1 -iname "*${MAPPING_MATCH}*.xml" \
               ! -iname "*${MAPPING_SUFFIX}*" | head -n1 || true)"
    if [[ -z "$SRC_XML" ]]; then
        warn "no mapping matching '$MAPPING_MATCH' -- skipping mapping step"
    else
        info "source mapping: $(basename "$SRC_XML")"
        mkdir -p "$CONTROLLER_DIR"

        BASE="$(basename "$SRC_XML")"
        DST_XML="$CONTROLLER_DIR/${BASE%.midi.xml}-${MAPPING_SUFFIX}.midi.xml"

        cp "$SRC_XML" "$DST_XML"
        cp "$REPO_DIR/mapping/$OVERRIDE_JS" "$CONTROLLER_DIR/$OVERRIDE_JS"

        # Mixxx resolves <scriptfiles> next to the mapping XML, so every script
        # the vendor mapping pulls in (its own, plus shared helpers like
        # midi-components / lodash) has to exist in $CONTROLLER_DIR too.
        # Symlink rather than copy: they then track the installed Mixxx version.
        while read -r js; do
            [[ -n "$js" && "$js" == *.js ]] || continue
            [[ "$js" == "$OVERRIDE_JS" ]] && continue
            if [[ -e "$SYS_CONTROLLERS/$js" ]]; then
                ln -sf "$SYS_CONTROLLERS/$js" "$CONTROLLER_DIR/$js"
                info "linked $js"
            else
                warn "mapping references $js, not found in $SYS_CONTROLLERS"
            fi
        done < <(grep -o 'filename="[^"]*"' "$DST_XML" | sed 's/^filename="//; s/"$//')

        # Distinguish it in the controller list. Only the first <name>, which is
        # the one inside <info>; note that a 0,/re/ address needs slash
        # delimiters even though the s/// after it does not.
        if ! grep -qF "$MAPPING_LABEL" "$DST_XML"; then
            sed -i "0,/<name>/s|<name>\\(.*\\)</name>|<name>\\1 $MAPPING_LABEL</name>|" "$DST_XML"
            grep -qF "$MAPPING_LABEL" "$DST_XML" \
                && info "mapping name suffixed with '$MAPPING_LABEL'" \
                || warn "could not patch <name> -- rename it by hand"
        fi

        # Append our override to <scriptfiles> if not already there.
        if grep -q "$OVERRIDE_JS" "$DST_XML"; then
            info "override already referenced"
        elif ! grep -q "</scriptfiles>" "$DST_XML"; then
            warn "no <scriptfiles> block in $(basename "$DST_XML") -- add it by hand"
        else
            sed -i "s|</scriptfiles>|    <file filename=\"$OVERRIDE_JS\" functionprefix=\"\"/>\n    </scriptfiles>|" \
                "$DST_XML"
            grep -q "$OVERRIDE_JS" "$DST_XML" \
                && info "override registered in $(basename "$DST_XML")" \
                || warn "could not patch <scriptfiles> -- add the <file> line by hand"
        fi

        chown -R "$TARGET_USER":"$TARGET_USER" "$MIXXX_DIR"
    fi
fi

# --- 5. optional: restore saved Mixxx preferences ---------------------------
if [[ -d "$REPO_DIR/config" ]]; then
    say "Restoring saved Mixxx config"
    mkdir -p "$MIXXX_DIR"
    for f in "$REPO_DIR/config"/*; do
        [[ -e "$f" ]] || continue
        cp -n "$f" "$MIXXX_DIR/" && info "restored $(basename "$f") (existing files kept)"
    done
    chown -R "$TARGET_USER":"$TARGET_USER" "$MIXXX_DIR"
fi

# --- report ------------------------------------------------------------------
say "Done. Verify after a reboot:"
cat <<EOF
   cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor   # performance
   systemctl status mixxx-cpu-governor.service                 # active (exited)
   vcgencmd measure_clock arm
   vcgencmd get_throttled        # want 0x0
   vcgencmd measure_temp
   su - $TARGET_USER -c 'ulimit -r; ulimit -l; id -nG'
   ps -eLo class,rtprio,comm | grep -i mixxx

   Then in Mixxx: select the "$MAPPING_LABEL" mapping under Preferences ->
   Controllers, and set the audio buffer under Preferences -> Sound Hardware.
EOF
