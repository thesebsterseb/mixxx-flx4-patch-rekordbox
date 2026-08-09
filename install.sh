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
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"
if [[ "$TARGET_USER" == "root" ]]; then
    TARGET_USER="pi"
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "$TARGET_HOME" ]]; then
    echo "!! no such user: $TARGET_USER (override with TARGET_USER=... )" >&2
    exit 1
fi
MIXXX_DIR="$TARGET_HOME/.mixxx"
CONTROLLER_DIR="$MIXXX_DIR/controllers"

# Name of the stock mapping to extend. Override if you switch controllers:
#   MAPPING_MATCH='DDJ-400' sudo -E ./install.sh
MAPPING_MATCH="${MAPPING_MATCH:-FLX4}"
MAPPING_SUFFIX="tightbend"
OVERRIDE_JS="Pioneer-DDJ-FLX4-tightbend.js"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   \033[33m!! %s\033[0m\n' "$*"; }

if [[ $EUID -ne 0 ]]; then
    echo "run me with sudo" >&2
    exit 1
fi

say "Tuning for user: $TARGET_USER  (home: $TARGET_HOME)"

# --- 1. CPU governor ---------------------------------------------------------
say "CPU governor -> performance"
if ! command -v cpufreq-info >/dev/null 2>&1; then
    info "installing cpufrequtils"
    apt-get update -qq
    apt-get install -y -qq cpufrequtils
fi
echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
# Present on some images, absent on others -- don't fail either way.
systemctl disable ondemand 2>/dev/null || true
systemctl restart cpufrequtils || warn "cpufrequtils restart failed"
info "now: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"

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
SYS_CONTROLLERS=""
for d in /usr/share/mixxx/controllers /usr/local/share/mixxx/controllers \
         /opt/mixxx/share/mixxx/controllers; do
    [[ -d "$d" ]] && { SYS_CONTROLLERS="$d"; break; }
done
if [[ -z "$SYS_CONTROLLERS" ]]; then
    warn "no system controller dir found -- skipping mapping step"
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

        # Symlink the vendor script next to our copy so it always resolves and
        # always tracks the installed Mixxx version.
        for js in "$SYS_CONTROLLERS"/*"${MAPPING_MATCH}"*script.js; do
            [[ -e "$js" ]] || continue
            ln -sf "$js" "$CONTROLLER_DIR/$(basename "$js")"
            info "linked $(basename "$js")"
        done

        # Distinguish it in the controller list.
        if ! grep -q "(tight bend)" "$DST_XML"; then
            sed -i "0,|<name>|s|<name>\\(.*\\)</name>|<name>\\1 (tight bend)</name>|" "$DST_XML" 2>/dev/null \
                || sed -i "s|<name>\\(.*\\)</name>|<name>\\1 (tight bend)</name>|" "$DST_XML"
        fi

        # Append our override to <scriptfiles> if not already there.
        if grep -q "$OVERRIDE_JS" "$DST_XML"; then
            info "override already referenced"
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
   cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
   vcgencmd measure_clock arm
   vcgencmd get_throttled        # want 0x0
   vcgencmd measure_temp
   su - $TARGET_USER -c 'ulimit -r; ulimit -l; id -nG'
   ps -eLo class,rtprio,comm | grep -i mixxx

   Then in Mixxx: select the "(tight bend)" mapping under Preferences ->
   Controllers, and set the audio buffer under Preferences -> Sound Hardware.
EOF
