#!/bin/sh
# Podkop Installer v0.2.5-improved
# Fixes: #1 #2 #3 #4 #5 | Improvements: #13 #14 #15 #16 #17 #18 #19

REPO="https://api.github.com/repos/itdoginfo/podkop/releases/latest"

IS_SHOULD_RESTART_NETWORK=
DOWNLOAD_DIR="/tmp/podkop"
INSTALLED_PACKAGES=""

# Detect package format: OpenWrt 24.10+ uses apk, older uses opkg/ipk
detect_pkg_format() {
    if command -v apk >/dev/null 2>&1; then
        PKG_EXT="apk"
        PKG_MGR="apk"
    else
        PKG_EXT="ipk"
        PKG_MGR="opkg"
    fi
}
detect_pkg_format
REQUIRED_SPACE=20480  # Fix #5: 20MB in KB (was 1024 with comment saying 20MB)

# --- #14: Colored logs with severity levels ---
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_CYAN="\033[0;36m"
COLOR_BOLD="\033[1m"
COLOR_RESET="\033[0m"

log_info() {
    printf "${COLOR_GREEN}[INFO]${COLOR_RESET} %s\n" "$1"
}

log_warn() {
    printf "${COLOR_YELLOW}[WARN]${COLOR_RESET} %s\n" "$1"
}

log_error() {
    printf "${COLOR_RED}[ERROR]${COLOR_RESET} %s\n" "$1"
}

log_step() {
    printf "\n${COLOR_CYAN}${COLOR_BOLD}>>> %s${COLOR_RESET}\n" "$1"
}

# --- #15: Rollback mechanism ---
rollback() {
    log_error "Installation failed! Rolling back..."

    for pkg in $INSTALLED_PACKAGES; do
        log_warn "Removing $pkg..."
        opkg remove "$pkg" 2>/dev/null
    done

    rm -rf "$DOWNLOAD_DIR"

    if [ -f /etc/config/dhcp-old ]; then
        log_warn "Restoring dhcp config..."
        mv /etc/config/dhcp-old /etc/config/dhcp
    fi

    log_error "Rollback complete. System restored to previous state."
    exit 1
}

# Track installed package for rollback
track_install() {
    INSTALLED_PACKAGES="$INSTALLED_PACKAGES $1"
}

# --- #19: Download with progress bar ---
download_with_progress() {
    local url="$1"
    local output="$2"
    local description="$3"

    if command -v curl >/dev/null 2>&1; then
        curl -L --progress-bar -o "$output" "$url"
    else
        log_info "Downloading $description..."
        wget -q -O "$output" "$url"
    fi

    if [ $? -ne 0 ] || [ ! -s "$output" ]; then
        log_error "Failed to download: $description"
        return 1
    fi
    return 0
}

# --- #4: Package verification ---
verify_pkg() {
    local filepath="$1"
    local filename=$(basename "$filepath")

    if [ ! -s "$filepath" ]; then
        log_error "$filename is empty or missing"
        return 1
    fi

    local fsize=$(wc -c < "$filepath")

    # Check if file is HTML (GitHub error page)
    if head -c 15 "$filepath" 2>/dev/null | grep -qi '<!doctype\|<html'; then
        log_error "$filename is an HTML page, not a package (download failed)"
        return 1
    fi

    # Minimum size check (valid packages are > 1KB)
    if [ "$fsize" -lt 1024 ]; then
        log_error "$filename is too small (${fsize} bytes) — likely corrupted"
        return 1
    fi

    log_info "$filename verified OK (${fsize} bytes)"
    return 0
}

# --- #13: Non-interactive mode ---
parse_args() {
    NONINTERACTIVE=0
    TUNNEL_TYPE=""
    INSTALL_RUSSIAN=0
    UPGRADE_ONLY=0
    DO_UNINSTALL=0
    DO_CONFIGURE=0

    while [ $# -gt 0 ]; do
        case "$1" in
        --non-interactive|-n)
            NONINTERACTIVE=1
            ;;
        --tunnel|-t)
            shift
            TUNNEL_TYPE="$1"
            ;;
        --russian|-r)
            INSTALL_RUSSIAN=1
            ;;
        --upgrade-only|-u)
            UPGRADE_ONLY=1
            ;;
        --uninstall)
            DO_UNINSTALL=1
            ;;
        --configure|-c)
            DO_CONFIGURE=1
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
        esac
        shift
    done
}

show_help() {
    cat << 'HELP'
Podkop Installer v0.2.5-improved

Usage: sh install.sh [OPTIONS]

Options:
  -n, --non-interactive   Run without prompts (use with -t and -r)
  -t, --tunnel TYPE       Tunnel type: singbox, wireguard, amneziawg, openvpn, openconnect, skip
  -r, --russian           Install Russian translation
  -u, --upgrade-only      Only upgrade podkop packages
  -c, --configure         Change configuration (tunnel, kill switch)
  --uninstall             Remove podkop and restore system
  -h, --help              Show this help

Examples:
  sh install.sh                              # Interactive install
  sh install.sh -n -t singbox -r             # Non-interactive: sing-box + Russian
  sh install.sh --uninstall                  # Remove podkop
  sh install.sh -u                           # Upgrade only

Environment variables (for non-interactive mode):
  PODKOP_TUNNEL=singbox|wireguard|amneziawg|openvpn|openconnect|skip
  PODKOP_RUSSIAN=1
  PODKOP_UPGRADE_ONLY=1
HELP
}

# --- #16: Uninstall option ---
uninstall() {
    log_step "Uninstalling Podkop"

    if [ -f /etc/init.d/podkop ]; then
        log_info "Stopping podkop..."
        /etc/init.d/podkop stop 2>/dev/null
        /etc/init.d/podkop disable 2>/dev/null
    fi

    log_info "Removing packages..."
    if [ "$PKG_MGR" = "apk" ]; then
        apk del luci-i18n-podkop-ru 2>/dev/null
        apk del luci-app-podkop 2>/dev/null
        apk del podkop 2>/dev/null
    else
        opkg remove luci-i18n-podkop-ru 2>/dev/null
        opkg remove luci-app-podkop 2>/dev/null
        opkg remove podkop 2>/dev/null
    fi

    log_info "Cleaning up routing tables..."
    grep -q "105 podkop" /etc/iproute2/rt_tables 2>/dev/null && \
        sed -i '/105 podkop/d' /etc/iproute2/rt_tables
    grep -q "106 podkop2" /etc/iproute2/rt_tables 2>/dev/null && \
        sed -i '/106 podkop2/d' /etc/iproute2/rt_tables

    log_info "Cleaning up nftables..."
    nft delete table inet PodkopTable 2>/dev/null

    log_info "Cleaning up ip rules..."
    ip rule del fwmark 0x105 table podkop priority 105 2>/dev/null
    ip rule del fwmark 0x106 table podkop2 priority 106 2>/dev/null

    log_info "Cleaning up routes..."
    ip route flush table podkop 2>/dev/null
    ip route flush table podkop2 2>/dev/null

    log_info "Cleaning up dnsmasq..."
    rm -f /tmp/dnsmasq.d/podkop*
    /etc/init.d/dnsmasq restart 2>/dev/null

    log_info "Cleaning up cron..."
    (crontab -l 2>/dev/null | grep -v "/etc/init.d/podkop") | crontab - 2>/dev/null

    log_info "Removing symlink..."
    rm -f /usr/sbin/podkop

    # Remove kill switch if installed
    rm -f /etc/hotplug.d/iface/99-*-default

    log_info "Podkop has been completely removed."
    exit 0
}

# --- Change configuration menu ---
configure_menu() {
    log_step "Podkop Configuration"

    if [ ! -f /etc/init.d/podkop ]; then
        log_error "Podkop is not installed. Run install first."
        exit 1
    fi

    printf "${COLOR_GREEN}${COLOR_BOLD}What do you want to configure?${COLOR_RESET}\n"
    echo "1) Change tunnel/proxy (reinstall VPN software)"
    echo "2) Reconfigure WireGuard/AmneziaWG interface"
    echo "3) Install/remove Kill Switch"
    echo "4) Back to main menu"

    while true; do
        read -r -p '' CONFIG_CHOICE
        case $CONFIG_CHOICE in
        1)
            add_tunnel
            break
            ;;
        2)
            printf "${COLOR_GREEN}${COLOR_BOLD}Which interface to reconfigure?${COLOR_RESET}\n"
            echo "1) WireGuard (wg0)"
            echo "2) AmneziaWG (awg0)"
            while true; do
                read -r -p '' WG_CHOICE
                case $WG_CHOICE in
                1) wg_awg_setup Wireguard; break ;;
                2) wg_awg_setup AmneziaWG; break ;;
                *) echo "Choose 1 or 2" ;;
                esac
            done
            handler_network_restart
            if [ "$IS_SHOULD_RESTART_NETWORK" ]; then
                log_step "Restarting network"
                /etc/init.d/network restart
            fi
            break
            ;;
        3)
            if ls /etc/hotplug.d/iface/99-*-default >/dev/null 2>&1; then
                printf "${COLOR_YELLOW}Kill Switch is already installed. Remove it? (y/n)${COLOR_RESET}\n"
                while true; do
                    read -r -p '' KS_REMOVE
                    case $KS_REMOVE in
                    y)
                        rm -f /etc/hotplug.d/iface/99-*-default
                        log_info "Kill Switch removed."
                        break
                        ;;
                    n) break ;;
                    *) echo "Please enter y or n" ;;
                    esac
                done
            else
                install_killswitch
            fi
            break
            ;;
        4)
            main
            return
            ;;
        *) echo "Choose from 1-4" ;;
        esac
    done

    log_info "Configuration updated."
    exit 0
}

# --- Main ---
main() {
    # Apply environment variables for non-interactive mode
    [ -n "$PODKOP_TUNNEL" ] && TUNNEL_TYPE="$PODKOP_TUNNEL"
    [ "$PODKOP_RUSSIAN" = "1" ] && INSTALL_RUSSIAN=1
    [ "$PODKOP_UPGRADE_ONLY" = "1" ] && UPGRADE_ONLY=1

    # Initial menu (only interactive, only if podkop already installed)
    if [ "$NONINTERACTIVE" -eq 0 ] && [ -f /etc/init.d/podkop ] && [ "$UPGRADE_ONLY" -eq 0 ]; then
        printf "\n${COLOR_CYAN}${COLOR_BOLD}Podkop detected on this system.${COLOR_RESET}\n"
        echo "1) Upgrade / Reinstall"
        echo "2) Change configuration"
        echo "3) Uninstall"

        while true; do
            read -r -p '' INIT_CHOICE
            case $INIT_CHOICE in
            1) break ;;
            2) configure_menu; return ;;
            3) uninstall; return ;;
            *) echo "Choose 1, 2, or 3" ;;
            esac
        done
    fi

    # --- #18: OpenWrt version check ---
    check_system

    log_step "Downloading packages from GitHub"

    # Check GitHub connectivity first
    if ! wget -q --spider "https://github.com" 2>/dev/null; then
        if ! curl -m 5 -s "https://github.com" >/dev/null 2>&1; then
            log_error "Cannot connect to GitHub. Check your internet connection."
            exit 1
        fi
    fi

    log_info "Package format: .$PKG_EXT (package manager: $PKG_MGR)"
    wget -qO- "$REPO" | grep -o "https://[^\"]*\\.$PKG_EXT" | while read -r url; do
        filename=$(basename "$url")
        download_with_progress "$url" "$DOWNLOAD_DIR/$filename" "$filename"
    done

    # Verify downloaded packages (#4)
    log_step "Verifying downloaded packages"
    for pkg in "$DOWNLOAD_DIR"/*.$PKG_EXT; do
        [ -f "$pkg" ] || continue
        if ! verify_pkg "$pkg"; then
            log_error "Package verification failed. Aborting."
            exit 1
        fi
    done

    log_step "Updating package lists"
    if [ "$PKG_MGR" = "apk" ]; then
        apk update || { log_error "apk update failed"; exit 1; }
    else
        opkg update || { log_error "opkg update failed"; exit 1; }
    fi

    # dnsmasq-full
    if [ "$PKG_MGR" = "apk" ]; then
        if apk list --installed 2>/dev/null | grep -q dnsmasq-full; then
            log_info "dnsmasq-full already installed"
        else
            log_step "Installing dnsmasq-full"
            apk add dnsmasq-full || { log_error "Failed to install dnsmasq-full"; rollback; }
            track_install "dnsmasq-full"
        fi
    else
        if opkg list-installed | grep -q dnsmasq-full; then
            log_info "dnsmasq-full already installed"
        else
            log_step "Installing dnsmasq-full"
            cd /tmp/ && opkg download dnsmasq-full
            if ! (opkg remove dnsmasq && opkg install dnsmasq-full --cache /tmp/); then
                log_error "Failed to install dnsmasq-full"
                rollback
            fi
            track_install "dnsmasq-full"
            [ -f /etc/config/dhcp-opkg ] && cp /etc/config/dhcp /etc/config/dhcp-old && mv /etc/config/dhcp-opkg /etc/config/dhcp
        fi
    fi

    # confdir for OpenWrt 24.x (Fix #3: typo "alreadt" -> "already")
    openwrt_release=$(cat /etc/openwrt_release | grep -Eo '[0-9]{2}[.][0-9]{2}[.][0-9]*' | cut -d '.' -f 1 | tail -n 1)
    if [ "$openwrt_release" -ge 24 ] 2>/dev/null; then
        if uci get dhcp.@dnsmasq[0].confdir 2>/dev/null | grep -q /tmp/dnsmasq.d; then
            log_info "confdir already set"
        else
            log_info "Setting confdir"
            uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
            uci commit dhcp
        fi
    fi

    # Upgrade or fresh install
    if [ -f "/etc/init.d/podkop" ]; then
        if [ "$UPGRADE_ONLY" -eq 1 ] || { [ "$NONINTERACTIVE" -eq 1 ] && [ -z "$TUNNEL_TYPE" ]; }; then
            log_info "Upgrading podkop..."
        else
            if [ "$NONINTERACTIVE" -eq 0 ]; then
                printf "${COLOR_GREEN}${COLOR_BOLD}Podkop is already installed. Just upgrade it? (y/n)${COLOR_RESET}\n"
                printf "${COLOR_GREEN}y - Only upgrade podkop${COLOR_RESET}\n"
                printf "${COLOR_GREEN}n - Upgrade and install proxy or tunnels${COLOR_RESET}\n"

                while true; do
                    read -r -p '' UPDATE
                    case $UPDATE in
                    y) log_info "Upgrading podkop..."; break ;;
                    n) add_tunnel; break ;;
                    *) echo "Please enter y or n" ;;
                    esac
                done
            else
                add_tunnel
            fi
        fi
    else
        log_info "Fresh install of podkop..."
        if [ "$NONINTERACTIVE" -eq 0 ] || [ -n "$TUNNEL_TYPE" ]; then
            add_tunnel
        fi
    fi

    # Install podkop packages
    log_step "Installing podkop packages"
    if [ "$PKG_MGR" = "apk" ]; then
        if ! apk add --allow-untrusted "$DOWNLOAD_DIR"/podkop*.$PKG_EXT; then
            log_error "Failed to install podkop"
            rollback
        fi
        track_install "podkop"

        if ! apk add --allow-untrusted "$DOWNLOAD_DIR"/luci-app-podkop*.$PKG_EXT; then
            log_error "Failed to install luci-app-podkop"
            rollback
        fi
        track_install "luci-app-podkop"
    else
        if ! opkg install "$DOWNLOAD_DIR"/podkop*.$PKG_EXT; then
            log_error "Failed to install podkop"
            rollback
        fi
        track_install "podkop"

        if ! opkg install "$DOWNLOAD_DIR"/luci-app-podkop*.$PKG_EXT; then
            log_error "Failed to install luci-app-podkop"
            rollback
        fi
        track_install "luci-app-podkop"
    fi

    # Russian translation
    if [ "$NONINTERACTIVE" -eq 1 ]; then
        if [ "$INSTALL_RUSSIAN" -eq 1 ]; then
            if [ "$PKG_MGR" = "apk" ]; then
                apk add --allow-untrusted "$DOWNLOAD_DIR"/luci-i18n-podkop-ru*.$PKG_EXT
            else
                opkg install "$DOWNLOAD_DIR"/luci-i18n-podkop-ru*.$PKG_EXT
            fi
        fi
    else
        echo "Русский язык интерфейса ставим? y/n (Need a Russian translation?)"
        while true; do
            read -r -p '' RUS
            case $RUS in
            y)
                if [ "$PKG_MGR" = "apk" ]; then
                    apk add --allow-untrusted "$DOWNLOAD_DIR"/luci-i18n-podkop-ru*.$PKG_EXT
                else
                    opkg install "$DOWNLOAD_DIR"/luci-i18n-podkop-ru*.$PKG_EXT
                fi
                break
                ;;
            n) break ;;
            *) echo "Please enter y or n" ;;
            esac
        done
    fi

    # --- #17: Optional Kill Switch ---
    if [ "$NONINTERACTIVE" -eq 0 ]; then
        printf "\n${COLOR_GREEN}${COLOR_BOLD}Install kill switch? (blocks internet if VPN drops) y/n${COLOR_RESET}\n"
        while true; do
            read -r -p '' KILLSWITCH
            case $KILLSWITCH in
            y)
                install_killswitch
                break
                ;;
            n) break ;;
            *) echo "Please enter y or n" ;;
            esac
        done
    fi

    # Cleanup
    rm -f "$DOWNLOAD_DIR"/*.$PKG_EXT

    if [ "$IS_SHOULD_RESTART_NETWORK" ]; then
        log_step "Restarting network"
        /etc/init.d/network restart
    fi

    log_step "Installation complete!"
    log_info "Open LuCI at http://$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d'/' -f1 || echo '192.168.1.1') -> Services -> Podkop"
}

# --- #17: Kill Switch installation ---
install_killswitch() {
    log_step "Installing Kill Switch"

    # Determine interface from config
    local vpn_iface=""
    if [ -f /etc/config/podkop ]; then
        vpn_iface=$(uci get podkop.main.interface 2>/dev/null)
    fi

    if [ -z "$vpn_iface" ]; then
        printf "Enter VPN interface name (e.g., wg0, awg0, tun0): "
        read -r vpn_iface
    fi

    if [ -z "$vpn_iface" ]; then
        log_warn "No interface specified, skipping kill switch"
        return
    fi

    cat << EOF > /etc/hotplug.d/iface/99-${vpn_iface}-default
#!/bin/sh

[ "\$INTERFACE" = "$vpn_iface" ] || exit 0

flush_defaults() {
    while ip route del default 2>/dev/null; do :; done
}

case "\$ACTION" in
    ifup|up|link-up)
        ip route del blackhole default 2>/dev/null
        flush_defaults
        ip route add default dev $vpn_iface metric 10
        ;;
    ifdown|down|link-down)
        flush_defaults
        ip route add blackhole default
        ;;
    *)
        if ! ip link show $vpn_iface 2>/dev/null | grep -q "state UP"; then
            flush_defaults
            ip route add blackhole default 2>/dev/null
        fi
        ;;
esac
EOF

    chmod +x /etc/hotplug.d/iface/99-${vpn_iface}-default
    log_info "Kill switch installed for interface: $vpn_iface"
}

add_tunnel() {
    if [ "$NONINTERACTIVE" -eq 1 ] && [ -n "$TUNNEL_TYPE" ]; then
        case "$TUNNEL_TYPE" in
        singbox|1)     TUNNEL=1 ;;
        wireguard|2)   TUNNEL=2 ;;
        amneziawg|3)   TUNNEL=3 ;;
        openvpn|4)     TUNNEL=4 ;;
        openconnect|5) TUNNEL=5 ;;
        skip|6)        TUNNEL=6 ;;
        *)
            log_error "Unknown tunnel type: $TUNNEL_TYPE"
            log_info "Valid types: singbox, wireguard, amneziawg, openvpn, openconnect, skip"
            exit 1
            ;;
        esac
    else
        echo "What type of VPN or proxy will be used? We also can automatically configure Wireguard and Amnezia WireGuard."
        echo "1) VLESS, Shadowsocks (A sing-box will be installed)"
        echo "2) Wireguard"
        echo "3) AmneziaWG"
        echo "4) OpenVPN"
        echo "5) OpenConnect"
        echo "6) Skip this step"

        while true; do
            read -r -p '' TUNNEL
            case $TUNNEL in
            1|2|3|4|5|6) break ;;
            *) echo "Choose from the following options (1-6)" ;;
            esac
        done
    fi

    case $TUNNEL in
    1)
        log_step "Installing sing-box"
        if ! opkg install sing-box; then
            log_error "Failed to install sing-box"
            rollback
        fi
        track_install "sing-box"
        ;;

    2)
        log_step "Installing WireGuard"
        if ! opkg install wireguard-tools luci-proto-wireguard; then
            log_error "Failed to install WireGuard packages"
            rollback
        fi
        track_install "wireguard-tools"

        if [ "$NONINTERACTIVE" -eq 0 ]; then
            printf "${COLOR_GREEN}${COLOR_BOLD}Do you want to configure the wireguard interface? (y/n):${COLOR_RESET}\n"
            read IS_SHOULD_CONFIGURE_WG_INTERFACE

            if [ "$IS_SHOULD_CONFIGURE_WG_INTERFACE" = "y" ] || [ "$IS_SHOULD_CONFIGURE_WG_INTERFACE" = "Y" ]; then
                wg_awg_setup Wireguard
            else
                printf "\e[1;32mUse these instructions to manual configure https://itdog.info/nastrojka-klienta-wireguard-na-openwrt/\e[0m\n"
            fi
        fi
        ;;

    3)
        log_step "Installing AmneziaWG"
        install_awg_packages

        if [ "$NONINTERACTIVE" -eq 0 ]; then
            printf "${COLOR_GREEN}${COLOR_BOLD}There are no instructions for manual configure yet. Do you want to configure the amneziawg interface? (y/n):${COLOR_RESET}\n"
            read IS_SHOULD_CONFIGURE_WG_INTERFACE

            if [ "$IS_SHOULD_CONFIGURE_WG_INTERFACE" = "y" ] || [ "$IS_SHOULD_CONFIGURE_WG_INTERFACE" = "Y" ]; then
                wg_awg_setup AmneziaWG
            fi
        fi
        ;;

    4)
        log_step "Installing OpenVPN"
        # Fix #1: removed duplicate "opkg install"
        if ! opkg install openvpn-openssl luci-app-openvpn; then
            log_error "Failed to install OpenVPN packages"
            rollback
        fi
        track_install "openvpn-openssl"
        printf "\e[1;32mUse these instructions to configure https://itdog.info/nastrojka-klienta-openvpn-na-openwrt/\e[0m\n"
        ;;

    5)
        log_step "Installing OpenConnect"
        # Fix #2: removed duplicate "opkg install"
        if ! opkg install openconnect luci-proto-openconnect; then
            log_error "Failed to install OpenConnect packages"
            rollback
        fi
        track_install "openconnect"
        printf "\e[1;32mUse these instructions to configure https://itdog.info/nastrojka-klienta-openconnect-na-openwrt/\e[0m\n"
        ;;

    6)
        log_info "Skipping tunnel installation."
        ;;
    esac
}

handler_network_restart() {
    IS_SHOULD_RESTART_NETWORK=true
}

install_awg_packages() {
    # Получение pkgarch с наибольшим приоритетом
    PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')

    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    PKGPOSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
    BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/"

    AWG_DIR="/tmp/amneziawg"
    mkdir -p "$AWG_DIR"

    if opkg list-installed | grep -q kmod-amneziawg; then
        log_info "kmod-amneziawg already installed"
    else
        KMOD_AMNEZIAWG_FILENAME="kmod-amneziawg${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${KMOD_AMNEZIAWG_FILENAME}"
        download_with_progress "$DOWNLOAD_URL" "$AWG_DIR/$KMOD_AMNEZIAWG_FILENAME" "kmod-amneziawg"

        if [ $? -ne 0 ]; then
            log_error "Error downloading kmod-amneziawg. Please install manually and run the script again"
            exit 1
        fi

        if ! opkg install "$AWG_DIR/$KMOD_AMNEZIAWG_FILENAME"; then
            log_error "Error installing kmod-amneziawg. Please install manually and run the script again"
            exit 1
        fi
        log_info "kmod-amneziawg installed successfully"
    fi

    if opkg list-installed | grep -q amneziawg-tools; then
        log_info "amneziawg-tools already installed"
    else
        AMNEZIAWG_TOOLS_FILENAME="amneziawg-tools${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${AMNEZIAWG_TOOLS_FILENAME}"
        download_with_progress "$DOWNLOAD_URL" "$AWG_DIR/$AMNEZIAWG_TOOLS_FILENAME" "amneziawg-tools"

        if [ $? -ne 0 ]; then
            log_error "Error downloading amneziawg-tools. Please install manually and run the script again"
            exit 1
        fi

        if ! opkg install "$AWG_DIR/$AMNEZIAWG_TOOLS_FILENAME"; then
            log_error "Error installing amneziawg-tools. Please install manually and run the script again"
            exit 1
        fi
        log_info "amneziawg-tools installed successfully"
    fi

    if opkg list-installed | grep -q luci-app-amneziawg; then
        log_info "luci-app-amneziawg already installed"
    else
        LUCI_APP_AMNEZIAWG_FILENAME="luci-app-amneziawg${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${LUCI_APP_AMNEZIAWG_FILENAME}"
        download_with_progress "$DOWNLOAD_URL" "$AWG_DIR/$LUCI_APP_AMNEZIAWG_FILENAME" "luci-app-amneziawg"

        if [ $? -ne 0 ]; then
            log_error "Error downloading luci-app-amneziawg. Please install manually and run the script again"
            exit 1
        fi

        if ! opkg install "$AWG_DIR/$LUCI_APP_AMNEZIAWG_FILENAME"; then
            log_error "Error installing luci-app-amneziawg. Please install manually and run the script again"
            exit 1
        fi
        log_info "luci-app-amneziawg installed successfully"
    fi

    rm -rf "$AWG_DIR"
}

wg_awg_setup() {
    PROTOCOL_NAME=$1
    printf "${COLOR_GREEN}${COLOR_BOLD}Configure ${PROTOCOL_NAME}${COLOR_RESET}\n"
    if [ "$PROTOCOL_NAME" = 'Wireguard' ]; then
        INTERFACE_NAME="wg0"
        CONFIG_NAME="wireguard_wg0"
        PROTO="wireguard"
        ZONE_NAME="wg"
    fi

    if [ "$PROTOCOL_NAME" = 'AmneziaWG' ]; then
        INTERFACE_NAME="awg0"
        CONFIG_NAME="amneziawg_awg0"
        PROTO="amneziawg"
        ZONE_NAME="awg"
    fi

    printf "\n${COLOR_CYAN}${COLOR_BOLD}Paste your full WG/AWG config below, then press Enter on empty line:${COLOR_RESET}\n"
    log_info "(paste the [Interface] + [Peer] block, then hit Enter twice)"

    # Read multiline config (stop on two consecutive empty lines or EOF)
    WG_CONFIG=""
    PREV_EMPTY=0
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            if [ "$PREV_EMPTY" -eq 1 ] && [ -n "$WG_CONFIG" ]; then
                break
            fi
            PREV_EMPTY=1
        else
            PREV_EMPTY=0
        fi
        WG_CONFIG="${WG_CONFIG}${line}
"
    done

    # Parse config
    parse_wg_value() {
        echo "$WG_CONFIG" | grep -i "^$1" | head -1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//'
    }

    WG_PRIVATE_KEY_INT=$(parse_wg_value "PrivateKey")
    WG_IP=$(parse_wg_value "Address")
    WG_PUBLIC_KEY_INT=$(parse_wg_value "PublicKey")
    WG_PRESHARED_KEY_INT=$(parse_wg_value "PresharedKey")

    # Parse Endpoint (host:port)
    ENDPOINT_FULL=$(parse_wg_value "Endpoint")
    WG_ENDPOINT_INT=$(echo "$ENDPOINT_FULL" | cut -d':' -f1)
    WG_ENDPOINT_PORT_INT=$(echo "$ENDPOINT_FULL" | cut -d':' -f2)
    WG_ENDPOINT_PORT_INT=${WG_ENDPOINT_PORT_INT:-51820}

    # Parse AWG-specific values
    if [ "$PROTOCOL_NAME" = 'AmneziaWG' ]; then
        AWG_JC=$(parse_wg_value "Jc")
        AWG_JMIN=$(parse_wg_value "Jmin")
        AWG_JMAX=$(parse_wg_value "Jmax")
        AWG_S1=$(parse_wg_value "S1")
        AWG_S2=$(parse_wg_value "S2")
        AWG_H1=$(parse_wg_value "H1")
        AWG_H2=$(parse_wg_value "H2")
        AWG_H3=$(parse_wg_value "H3")
        AWG_H4=$(parse_wg_value "H4")

        # If no AWG values found, use auto-obfuscation defaults
        if [ -z "$AWG_JC" ]; then
            log_info "No AWG params found, using automatic obfuscation defaults"
            AWG_JC=4; AWG_JMIN=40; AWG_JMAX=70
            AWG_S1=0; AWG_S2=0
            AWG_H1=1; AWG_H2=2; AWG_H3=3; AWG_H4=4
        fi
    fi

    # Validate required fields
    if [ -z "$WG_PRIVATE_KEY_INT" ] || [ -z "$WG_IP" ] || [ -z "$WG_PUBLIC_KEY_INT" ] || [ -z "$WG_ENDPOINT_INT" ]; then
        log_error "Failed to parse config. Missing required fields."
        log_warn "PrivateKey: ${WG_PRIVATE_KEY_INT:-(empty)}"
        log_warn "Address: ${WG_IP:-(empty)}"
        log_warn "PublicKey: ${WG_PUBLIC_KEY_INT:-(empty)}"
        log_warn "Endpoint: ${WG_ENDPOINT_INT:-(empty)}"
        return 1
    fi

    # Show parsed values
    log_info "Parsed configuration:"
    log_info "  PrivateKey: ${WG_PRIVATE_KEY_INT:0:8}..."
    log_info "  Address: $WG_IP"
    log_info "  PublicKey: ${WG_PUBLIC_KEY_INT:0:8}..."
    log_info "  Endpoint: $WG_ENDPOINT_INT:$WG_ENDPOINT_PORT_INT"
    if [ -n "$WG_PRESHARED_KEY_INT" ]; then
        log_info "  PresharedKey: ${WG_PRESHARED_KEY_INT:0:8}..."
    fi
    if [ "$PROTOCOL_NAME" = 'AmneziaWG' ]; then
        log_info "  Jc=$AWG_JC Jmin=$AWG_JMIN Jmax=$AWG_JMAX S1=$AWG_S1 S2=$AWG_S2 H1=$AWG_H1 H2=$AWG_H2 H3=$AWG_H3 H4=$AWG_H4"
    fi

    uci set network.${INTERFACE_NAME}=interface
    uci set network.${INTERFACE_NAME}.proto=$PROTO
    uci set network.${INTERFACE_NAME}.private_key=$WG_PRIVATE_KEY_INT
    uci set network.${INTERFACE_NAME}.listen_port='51821'
    uci set network.${INTERFACE_NAME}.addresses=$WG_IP

    if [ "$PROTOCOL_NAME" = 'AmneziaWG' ]; then
        uci set network.${INTERFACE_NAME}.awg_jc=$AWG_JC
        uci set network.${INTERFACE_NAME}.awg_jmin=$AWG_JMIN
        uci set network.${INTERFACE_NAME}.awg_jmax=$AWG_JMAX
        uci set network.${INTERFACE_NAME}.awg_s1=$AWG_S1
        uci set network.${INTERFACE_NAME}.awg_s2=$AWG_S2
        uci set network.${INTERFACE_NAME}.awg_h1=$AWG_H1
        uci set network.${INTERFACE_NAME}.awg_h2=$AWG_H2
        uci set network.${INTERFACE_NAME}.awg_h3=$AWG_H3
        uci set network.${INTERFACE_NAME}.awg_h4=$AWG_H4
    fi

    if ! uci show network | grep -q ${CONFIG_NAME}; then
        uci add network ${CONFIG_NAME}
    fi

    uci set network.@${CONFIG_NAME}[0]=$CONFIG_NAME
    uci set network.@${CONFIG_NAME}[0].name="${INTERFACE_NAME}_client"
    uci set network.@${CONFIG_NAME}[0].public_key=$WG_PUBLIC_KEY_INT
    uci set network.@${CONFIG_NAME}[0].preshared_key=$WG_PRESHARED_KEY_INT
    uci set network.@${CONFIG_NAME}[0].route_allowed_ips='0'
    uci set network.@${CONFIG_NAME}[0].persistent_keepalive='25'
    uci set network.@${CONFIG_NAME}[0].endpoint_host=$WG_ENDPOINT_INT
    uci set network.@${CONFIG_NAME}[0].allowed_ips='0.0.0.0/0'
    uci set network.@${CONFIG_NAME}[0].endpoint_port=$WG_ENDPOINT_PORT_INT
    uci commit network

    if ! uci show firewall | grep -q "@zone.*name='${ZONE_NAME}'"; then
        log_info "Creating firewall zone"
        uci add firewall zone
        uci set firewall.@zone[-1].name=$ZONE_NAME
        uci set firewall.@zone[-1].network=$INTERFACE_NAME
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].input='REJECT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci set firewall.@zone[-1].family='ipv4'
        uci commit firewall
    fi

    if ! uci show firewall | grep -q "@forwarding.*name='${ZONE_NAME}'"; then
        log_info "Configuring forwarding"
        uci add firewall forwarding
        uci set firewall.@forwarding[-1]=forwarding
        uci set firewall.@forwarding[-1].name="${ZONE_NAME}-lan"
        uci set firewall.@forwarding[-1].dest=${ZONE_NAME}
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].family='ipv4'
        uci commit firewall
    fi

    handler_network_restart
}

# --- #18: System checks with version compatibility ---
check_system() {
    log_step "System Check"

    # Get router model
    MODEL=$(cat /tmp/sysinfo/model 2>/dev/null || echo "Unknown")
    log_info "Router model: $MODEL"

    # Check OpenWrt version
    if [ -f /etc/openwrt_release ]; then
        local owrt_ver=$(cat /etc/openwrt_release | grep DISTRIB_RELEASE | cut -d"'" -f2)
        log_info "OpenWrt version: $owrt_ver"

        local major_ver=$(echo "$owrt_ver" | cut -d'.' -f1)
        if [ "$major_ver" -lt 21 ] 2>/dev/null; then
            log_error "OpenWrt $owrt_ver is too old. Minimum required: 21.02"
            exit 1
        fi
    else
        log_warn "Cannot detect OpenWrt version"
    fi

    # Check available space (Fix #5: correct size)
    AVAILABLE_SPACE=$(df /tmp | awk 'NR==2 {print $4}')

    log_info "Available space: $((AVAILABLE_SPACE/1024))MB"
    log_info "Required space: $((REQUIRED_SPACE/1024))MB"

    if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
        log_error "Insufficient space in /tmp"
        log_error "Available: $((AVAILABLE_SPACE/1024))MB, Required: $((REQUIRED_SPACE/1024))MB"
        exit 1
    fi

    # Check DNS
    if ! nslookup github.com >/dev/null 2>&1; then
        log_warn "DNS resolution failed, trying to fix with NTP sync..."
        /usr/sbin/ntpd -q -p 194.190.168.1 -p 216.239.35.0 2>/dev/null
        if ! nslookup github.com >/dev/null 2>&1; then
            log_error "DNS is not working. Check your network."
            exit 1
        fi
    fi

    log_info "System check passed"
}

# --- Entry point ---
rm -rf "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"

parse_args "$@"

if [ "$DO_UNINSTALL" -eq 1 ]; then
    uninstall
fi

if [ "$DO_CONFIGURE" -eq 1 ]; then
    configure_menu
fi

main