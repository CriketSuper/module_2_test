#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

[[ -f "$ENV_FILE" ]] || {
    echo "ERROR: $ENV_FILE not found" >&2
    exit 1
}

# shellcheck disable=SC1090
source "$ENV_FILE"

required_variables=(
    HQ_SRV_IP BR_SRV_IP LINUX_SSH_USER LINUX_SSH_PASSWORD LINUX_SSH_PORT
    ISP_IP
    HQ_RTR_SSH_HOST BR_RTR_SSH_HOST ROUTER_SSH_USER ROUTER_SSH_PASSWORD
    ROUTER_SSH_PORT HQ_RTR_WAN_IP BR_RTR_WAN_IP
    HQ_WEB_EXTERNAL_PORT BR_APP_EXTERNAL_PORT
    DOMAIN_FQDN DOMAIN_USER DOMAIN_USER_PREFIX DOMAIN_USER_COUNT DOMAIN_GROUP
    RAID_DEVICE RAID_LEVEL RAID_MEMBER_COUNT RAID_MOUNT
    NFS_EXPORT NFS_CLIENT_MOUNT HQ_CLI_SUBNET NTP_STRATUM
    APP_CONTAINER DB_CONTAINER APP_PORT APP_INTERNAL_PORT APP_DB_NAME APP_DB_USER
    APP_DB_PASSWORD WEB_PORT WEB_DB_NAME WEB_DB_USER WEB_DB_PASSWORD
    WEB_DOMAIN DOCKER_DOMAIN
    AUTH_USER AUTH_PASSWORD AUTO_INSTALL
)

for variable_name in "${required_variables[@]}"; do
    [[ -n "${!variable_name:-}" ]] || {
        echo "ERROR: $variable_name is empty in $ENV_FILE" >&2
        exit 1
    }
done

HQ_SSH_HOST="${HQ_SSH_HOST:-$HQ_SRV_IP}"
HQ_SSH_PORT="${HQ_SSH_PORT:-$LINUX_SSH_PORT}"
BR_SSH_HOST="${BR_SSH_HOST:-$BR_SRV_IP}"
BR_SSH_PORT="${BR_SSH_PORT:-$LINUX_SSH_PORT}"
ISP_SSH_USER="${ISP_SSH_USER:-}"
ISP_SSH_PASSWORD="${ISP_SSH_PASSWORD:-}"
ISP_SSH_PORT="${ISP_SSH_PORT:-22}"
ISP_SSH_ENABLED="${ISP_SSH_ENABLED:-no}"

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_BOLD=$'\033[1m'
else
    C_RESET=
    C_RED=
    C_GREEN=
    C_YELLOW=
    C_BLUE=
    C_BOLD=
fi

declare -A RESULT_SCORE RESULT_TITLE RESULT_DETAIL
TOTAL_HALF_POINTS=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

log() {
    printf '%s[check]%s %s\n' "$C_BLUE" "$C_RESET" "$*"
}

warn() {
    printf '%sWARNING:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

set_result() {
    local number="$1"
    local score="$2"
    local title="$3"
    local detail="$4"

    RESULT_SCORE["$number"]="$score"
    RESULT_TITLE["$number"]="$title"
    RESULT_DETAIL["$number"]="$detail"

    case "$score" in
        1) TOTAL_HALF_POINTS=$((TOTAL_HALF_POINTS + 2)) ;;
        0.5) TOTAL_HALF_POINTS=$((TOTAL_HALF_POINTS + 1)) ;;
    esac
}

contains() {
    local haystack="$1"
    local needle="$2"
    grep -Fq -- "$needle" <<< "$haystack"
}

count_matches() {
    local text="$1"
    local pattern="$2"
    grep -Eoc -- "$pattern" <<< "$text" 2>/dev/null || true
}

web_status_code() {
    local url="$1"
    local credentials="${2:-}"
    local -a auth_args=()
    local code
    local status

    if [[ -n "$credentials" ]]; then
        auth_args=(--user "$credentials")
    fi

    code="$(
        curl --silent --show-error \
            --location \
            --max-redirs 5 \
            --connect-timeout 5 \
            --max-time 20 \
            --output /dev/null \
            --write-out '%{http_code}' \
            "${auth_args[@]}" \
            "$url" 2>/dev/null
    )"
    status=$?

    if ((status == 0)); then
        printf '%s\n' "${code:-000}"
    else
        printf '000\n'
    fi
}

remote_script() {
    local host="$1"
    local port="$2"
    local user="$3"
    local password="$4"
    local privileged="$5"
    local script="$6"
    local remote_shell="bash -s"
    local output
    local status

    if [[ "$privileged" == yes && "$user" != root ]]; then
        remote_shell="sudo -n bash -s"
    fi

    output="$(
        SSHPASS="$password" sshpass -e ssh \
        -p "$port" \
        -o BatchMode=no \
        -o ConnectTimeout=8 \
        -o ConnectionAttempts=1 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "$user@$host" "$remote_shell" <<< "$script"
    )"
    status=$?

    if ((status != 0)) && [[ "$privileged" == yes && "$user" != root ]]; then
        output="$(
            {
                printf '%s\n' "$password"
                printf '%s\n' "$script"
            } |
                SSHPASS="$password" sshpass -e ssh \
                    -p "$port" \
                    -o BatchMode=no \
                    -o ConnectTimeout=8 \
                    -o ConnectionAttempts=1 \
                    -o StrictHostKeyChecking=no \
                    -o UserKnownHostsFile=/dev/null \
                    -o LogLevel=ERROR \
                    "$user@$host" "sudo -S -p '' bash -s"
        )"
        status=$?
    fi

    if ((status != 0)); then
        printf '__CHECK_REMOTE_ERROR__ host=%s port=%s status=%s\n' \
            "$host" "$port" "$status"
    fi
    printf '%s\n' "$output"
    return "$status"
}

linux_remote() {
    local host="$1"
    local script="$2"
    local ssh_host="$host"
    local ssh_port="$LINUX_SSH_PORT"

    case "$host" in
        "$HQ_SRV_IP")
            ssh_host="$HQ_SSH_HOST"
            ssh_port="$HQ_SSH_PORT"
            ;;
        "$BR_SRV_IP")
            ssh_host="$BR_SSH_HOST"
            ssh_port="$BR_SSH_PORT"
            ;;
    esac

    remote_script \
        "$ssh_host" "$ssh_port" \
        "$LINUX_SSH_USER" "$LINUX_SSH_PASSWORD" yes "$script"
}

isp_remote() {
    local script="$1"
    [[ "$ISP_SSH_ENABLED" == yes ]] || return 2
    [[ -n "$ISP_SSH_USER" && -n "$ISP_SSH_PASSWORD" ]] || return 2
    remote_script \
        "$ISP_IP" "$ISP_SSH_PORT" \
        "$ISP_SSH_USER" "$ISP_SSH_PASSWORD" yes "$script"
}

probe_linux_ssh() {
    local host="$1"
    local port="$2"

    SSHPASS="$LINUX_SSH_PASSWORD" sshpass -e ssh \
        -p "$port" \
        -o BatchMode=no \
        -o ConnectTimeout=4 \
        -o ConnectionAttempts=1 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "$LINUX_SSH_USER@$host" true >/dev/null 2>&1
}

select_linux_ssh_paths() {
    if ! probe_linux_ssh "$HQ_SSH_HOST" "$HQ_SSH_PORT" &&
        probe_linux_ssh "$HQ_RTR_WAN_IP" "$LINUX_SSH_PORT"; then
        HQ_SSH_HOST="$HQ_RTR_WAN_IP"
        HQ_SSH_PORT="$LINUX_SSH_PORT"
        log "HQ-SRV checker access uses static NAT at $HQ_SSH_HOST:$HQ_SSH_PORT"
    fi

    if ! probe_linux_ssh "$BR_SSH_HOST" "$BR_SSH_PORT" &&
        probe_linux_ssh "$BR_RTR_WAN_IP" "$LINUX_SSH_PORT"; then
        BR_SSH_HOST="$BR_RTR_WAN_IP"
        BR_SSH_PORT="$LINUX_SSH_PORT"
        log "BR-SRV checker access uses static NAT at $BR_SSH_HOST:$BR_SSH_PORT"
    fi
}

install_dependencies() {
    local missing=()
    local command_name
    local package

    declare -A package_for=(
        [ssh]=openssh-clients
        [sshpass]=sshpass
        [expect]=expect
        [curl]=curl
        [host]=bind-utils
        [column]=util-linux
    )

    for command_name in "${!package_for[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("${package_for[$command_name]}")
    done

    ((${#missing[@]} == 0)) && return 0
    [[ "$AUTO_INSTALL" == yes ]] || {
        warn "Missing diagnostic packages: ${missing[*]}"
        return 1
    }
    [[ $EUID -eq 0 ]] || {
        warn "Run as root to install diagnostic packages: ${missing[*]}"
        return 1
    }

    log "Installing diagnostic packages: ${missing[*]}"
    apt-get update &&
        apt-get install -y "${missing[@]}"
}

create_router_expect() {
    cat > "$TMP_DIR/router-show.exp" <<'EXPECT'
#!/usr/bin/expect -f
set timeout 20
match_max 500000

set host [lindex $argv 0]
set port [lindex $argv 1]
set user [lindex $argv 2]
set password $env(ROUTER_CHECK_PASSWORD)
set enable_password $env(ROUTER_CHECK_ENABLE_PASSWORD)
set prompt_re {(?i)[a-z0-9_.-]+(\([^)\r\n]+\))*[>#][ \t]*}

proc fail {message} {
    puts stderr "ERROR: $message"
    exit 1
}

proc wait_prompt {} {
    global prompt_re timeout
    expect {
        -re {\x1b\[6n} {
            send -- "\033\[24;86R"
            exp_continue
        }
        -re {(?i)are you sure you want to continue connecting.*} {
            send -- "yes\r"
            exp_continue
        }
        -re $prompt_re { return }
        -re {(?i)permission denied} { fail "router authentication failed" }
        timeout { fail "router prompt timeout" }
        eof { fail "router connection closed" }
    }
}

proc wait_show {} {
    global prompt_re timeout
    expect {
        -re {\x1b\[6n} {
            send -- "\033\[24;86R"
            exp_continue
        }
        -re {(?i)(--more--|more:|press any key|press space)} {
            send -- " "
            exp_continue
        }
        -re $prompt_re { return }
        timeout { fail "show running-config timeout" }
        eof { fail "router connection closed during show running-config" }
    }
}

set env(SSHPASS) $password
spawn sshpass -e ssh -tt \
    -p $port \
    -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -- "$user@$host"

wait_prompt
send -- "enable\r"
expect {
    -re {(?i)password[[:space:]]*:[[:space:]]*} {
        if {$enable_password eq ""} {
            fail "enable password requested but not configured"
        }
        send -- "$enable_password\r"
        wait_prompt
    }
    -re $prompt_re {}
    timeout { fail "enable timeout" }
}

send -- "terminal length 0\r"
wait_prompt
send -- "show running-config\r"
wait_show
send -- "exit\r"
expect eof
EXPECT
    chmod 0700 "$TMP_DIR/router-show.exp"
}

router_config() {
    local host="$1"
    ROUTER_CHECK_PASSWORD="$ROUTER_SSH_PASSWORD" \
        ROUTER_CHECK_ENABLE_PASSWORD="${ROUTER_ENABLE_PASSWORD:-}" \
        "$TMP_DIR/router-show.exp" \
        "$host" "$ROUTER_SSH_PORT" "$ROUTER_SSH_USER" 2>/dev/null |
        sed -E $'s/\033\\[[0-9;?]*[[:alpha:]]//g'
}

check_1_samba() {
    local title="Samba DC и ввод HQ-CLI в домен"
    local output
    local dc_ok=no
    local joined_ok=no
    local local_user_ok=no
    local remote_error=no

    output="$(linux_remote "$BR_SRV_IP" "
systemctl is-active samba 2>/dev/null || true
samba-tool domain info 127.0.0.1 2>/dev/null || true
samba-tool computer show 'HQ-CLI$' 2>/dev/null || true
" 2>/dev/null)" || true

    contains "$output" "__CHECK_REMOTE_ERROR__" && remote_error=yes
    contains "$output" "active" &&
        contains "${output^^}" "${DOMAIN_FQDN^^}" && dc_ok=yes
    contains "${output^^}" "HQ-CLI" && joined_ok=yes

    if host -t SRV "_ldap._tcp.$DOMAIN_FQDN" "$BR_SRV_IP" >/dev/null 2>&1 &&
        timeout 3 bash -c "</dev/tcp/$BR_SRV_IP/389" >/dev/null 2>&1; then
        dc_ok=yes
    fi

    if [[ -s /etc/sssd/sssd.conf ]] &&
        grep -Fqi "$DOMAIN_FQDN" /etc/sssd/sssd.conf; then
        joined_ok=yes
    fi

    if getent passwd "$DOMAIN_USER" >/dev/null 2>&1 ||
        getent passwd "$DOMAIN_USER@$DOMAIN_FQDN" >/dev/null 2>&1; then
        local_user_ok=yes
        joined_ok=yes
    fi

    if [[ "$dc_ok" == yes && "$joined_ok" == yes && "$local_user_ok" == yes ]]; then
        set_result 1 1 "$title" "Samba активна, HQ-CLI и доменный пользователь видны"
    elif [[ "$dc_ok" == yes ]]; then
        set_result 1 0.5 "$title" "Контроллер доступен, но доменный вход на HQ-CLI не подтверждён"
    elif [[ "$remote_error" == yes ]]; then
        set_result 1 0 "$title" "BR-SRV недоступен проверяющему по SSH, LDAP/Samba также не отвечает"
    else
        set_result 1 0 "$title" "Работающий Samba DC не обнаружен"
    fi
}

check_2_users() {
    local title="Пользователи и группа hq"
    local output
    local users=0
    local members=0
    local i
    local candidate
    local remote_error=no

    output="$(linux_remote "$BR_SRV_IP" "
for i in \$(seq 1 $DOMAIN_USER_COUNT); do
    samba-tool user show '${DOMAIN_USER_PREFIX}'\"\$i\" >/dev/null 2>&1 && echo USER:\"\$i\"
done
samba-tool group listmembers '$DOMAIN_GROUP' 2>/dev/null || true
" 2>/dev/null)" || true

    contains "$output" "__CHECK_REMOTE_ERROR__" && remote_error=yes
    users="$(count_matches "$output" '^USER:[0-9]+$')"
    for ((i = 1; i <= DOMAIN_USER_COUNT; i++)); do
        grep -Fixq "${DOMAIN_USER_PREFIX}${i}" <<< "$output" && members=$((members + 1))
    done

    if ((users == 0)); then
        members=0
        for ((i = 1; i <= DOMAIN_USER_COUNT; i++)); do
            candidate="${DOMAIN_USER_PREFIX}${i}"
            if ! getent passwd "$candidate" >/dev/null 2>&1; then
                candidate="${DOMAIN_USER_PREFIX}${i}@$DOMAIN_FQDN"
                getent passwd "$candidate" >/dev/null 2>&1 || continue
            fi
            users=$((users + 1))
            if id -nG "$candidate" 2>/dev/null |
                tr ' ' '\n' |
                grep -Eiq "^${DOMAIN_GROUP}(@${DOMAIN_FQDN})?$"; then
                members=$((members + 1))
            fi
        done
    fi

    if ((users == DOMAIN_USER_COUNT && members == DOMAIN_USER_COUNT)); then
        set_result 2 1 "$title" "$users пользователей, все состоят в $DOMAIN_GROUP"
    elif ((users == DOMAIN_USER_COUNT)); then
        set_result 2 0.5 "$title" "$users пользователей, в группе $members"
    elif [[ "$remote_error" == yes && "$users" -eq 0 ]]; then
        set_result 2 0 "$title" "BR-SRV недоступен по SSH, через NSS найдено пользователей: 0"
    else
        set_result 2 0 "$title" "Найдено пользователей: $users из $DOMAIN_USER_COUNT"
    fi
}

check_3_sudo() {
    local title="Ограниченный sudo доменных пользователей"
    local policy
    local resolved_user="$DOMAIN_USER"
    local command_count=0
    local unrestricted=no

    if ! getent passwd "$resolved_user" >/dev/null 2>&1 &&
        getent passwd "$DOMAIN_USER@$DOMAIN_FQDN" >/dev/null 2>&1; then
        resolved_user="$DOMAIN_USER@$DOMAIN_FQDN"
    fi

    policy="$(sudo -l -U "$resolved_user" 2>/dev/null || true)"
    contains "$policy" "/bin/cat" && command_count=$((command_count + 1))
    contains "$policy" "/bin/grep" && command_count=$((command_count + 1))
    grep -Eq '(/bin/id|/usr/bin/id)' <<< "$policy" && command_count=$((command_count + 1))
    grep -Eq '^[[:space:]]*\(ALL([[:space:]]*:[[:space:]]*ALL)?\)[[:space:]]+(NOPASSWD:[[:space:]]*)?ALL[[:space:]]*$' \
        <<< "$policy" && unrestricted=yes

    if ((command_count == 3)) && [[ "$unrestricted" == no ]] &&
        grep -Eq 'NOPASSWD:.*(cat|HQ_LIMITED)' <<< "$policy"; then
        set_result 3 1 "$title" "cat, grep и id разрешены без пароля; полный sudo отсутствует"
    elif ((command_count > 0)); then
        set_result 3 0.5 "$title" "Ограничение найдено, но соответствует не полностью"
    else
        set_result 3 0 "$title" "Правило ограниченного sudo не найдено"
    fi
}

check_4_raid() {
    local title="RAID на HQ-SRV"
    local output
    local array_ok=no
    local level_ok=no
    local members_ok=no
    local partition_ok=no
    local filesystem_ok=no
    local mounted_ok=no
    local fstab_ok=no
    local matched=0
    local missing=()

    output="$(linux_remote "$HQ_SRV_IP" "
mdadm --detail '$RAID_DEVICE' 2>/dev/null || true
echo PARTITION:\$(lsblk -nrpo NAME,TYPE '$RAID_DEVICE' 2>/dev/null | awk '\$2==\"part\"{print \$1; exit}')
part=\$(lsblk -nrpo NAME,TYPE '$RAID_DEVICE' 2>/dev/null | awk '\$2==\"part\"{print \$1; exit}')
target=\${part:-$RAID_DEVICE}
echo FSTYPE:\$(blkid -o value -s TYPE \"\$target\" 2>/dev/null)
findmnt -nro TARGET,FSTYPE '$RAID_MOUNT' 2>/dev/null || true
grep -E '[[:space:]]$RAID_MOUNT[[:space:]]' /etc/fstab 2>/dev/null || true
" 2>/dev/null)" || true

    contains "$output" "$RAID_DEVICE" && array_ok=yes
    grep -Eqi "Raid Level[[:space:]]*:[[:space:]]*raid$RAID_LEVEL" <<< "$output" && level_ok=yes
    grep -Eqi "Raid Devices[[:space:]]*:[[:space:]]*$RAID_MEMBER_COUNT" <<< "$output" && members_ok=yes
    grep -Eq '^PARTITION:/dev/' <<< "$output" && partition_ok=yes
    contains "$output" "FSTYPE:ext4" && filesystem_ok=yes
    grep -Eq "^$RAID_MOUNT[[:space:]]+ext4" <<< "$output" && mounted_ok=yes
    grep -Eq "[[:space:]]$RAID_MOUNT[[:space:]]+ext4[[:space:]]" <<< "$output" && fstab_ok=yes

    for state in \
        "$array_ok" "$level_ok" "$members_ok" "$partition_ok" \
        "$filesystem_ok" "$mounted_ok" "$fstab_ok"; do
        [[ "$state" == yes ]] && matched=$((matched + 1))
    done

    [[ "$array_ok" == yes ]] || missing+=("устройство")
    [[ "$level_ok" == yes ]] || missing+=("уровень RAID")
    [[ "$members_ok" == yes ]] || missing+=("число дисков")
    [[ "$partition_ok" == yes ]] || missing+=("раздел")
    [[ "$filesystem_ok" == yes ]] || missing+=("ext4")
    [[ "$mounted_ok" == yes ]] || missing+=("монтирование")
    [[ "$fstab_ok" == yes ]] || missing+=("fstab")

    if [[ "$array_ok$level_ok$members_ok$partition_ok$filesystem_ok$mounted_ok$fstab_ok" == yesyesyesyesyesyesyes ]]; then
        set_result 4 1 "$title" "RAID$RAID_LEVEL, $RAID_MEMBER_COUNT диска, ext4 и автомонтирование настроены"
    elif ((matched >= 6)); then
        set_result 4 0.5 "$title" "Не совпадает: ${missing[*]}"
    else
        set_result 4 0 "$title" "Массив $RAID_DEVICE не обнаружен"
    fi
}

check_5_nfs() {
    local title="NFS и автомонтирование"
    local server_output
    local service_ok=no
    local export_ok=no
    local mounted_ok=no
    local source_ok=no
    local fstab_ok=no

    server_output="$(linux_remote "$HQ_SRV_IP" "
(systemctl is-active nfs-server 2>/dev/null || systemctl is-active nfs 2>/dev/null || true)
exportfs -v 2>/dev/null || true
" 2>/dev/null)" || true

    contains "$server_output" "active" && service_ok=yes
    contains "$server_output" "$NFS_EXPORT" &&
        contains "$server_output" "$HQ_CLI_SUBNET" &&
        contains "$server_output" "rw" && export_ok=yes

    mountpoint -q "$NFS_CLIENT_MOUNT" && mounted_ok=yes
    [[ "$(findmnt -nro SOURCE --target "$NFS_CLIENT_MOUNT" 2>/dev/null)" == "$HQ_SRV_IP:$NFS_EXPORT" ]] &&
        source_ok=yes
    awk -v source="$HQ_SRV_IP:$NFS_EXPORT" -v target="$NFS_CLIENT_MOUNT" \
        '$1 == source && $2 == target && $3 == "nfs" { found=1 } END { exit !found }' \
        /etc/fstab 2>/dev/null && fstab_ok=yes

    if [[ "$service_ok$export_ok$mounted_ok$source_ok$fstab_ok" == yesyesyesyesyes ]]; then
        set_result 5 1 "$title" "Экспорт и автомонтирование соответствуют заданию"
    elif [[ "$service_ok" == yes && "$mounted_ok" == yes ]]; then
        set_result 5 0.5 "$title" "NFS работает и смонтирован, но параметры отличаются"
    else
        set_result 5 0 "$title" "Работающая связка NFS не обнаружена"
    fi
}

check_6_ntp() {
    local title="Сервер сетевого времени на ISP"
    local output
    local active=no
    local stratum=no
    local upstream=no
    local allow=no
    local matched=0
    local local_output
    local expected_client_stratum=$((NTP_STRATUM + 1))
    local remote_error=no

    output="$(isp_remote "
systemctl is-active chronyd 2>/dev/null || true
cat /etc/chrony.conf 2>/dev/null || true
chronyc tracking 2>/dev/null || true
" 2>/dev/null)" || true

    contains "$output" "__CHECK_REMOTE_ERROR__" && remote_error=yes
    contains "$output" "active" && active=yes
    grep -Eq "^[[:space:]]*local[[:space:]]+stratum[[:space:]]+$NTP_STRATUM([[:space:]]|$)" \
        <<< "$output" && stratum=yes
    grep -Eq '^[[:space:]]*(server|pool)[[:space:]]+' <<< "$output" && upstream=yes
    grep -Eq '^[[:space:]]*allow[[:space:]]+' <<< "$output" && allow=yes

    local_output="$(
        {
            systemctl is-active chronyd 2>/dev/null || true
            cat /etc/chrony.conf 2>/dev/null || true
            chronyc -n sources 2>/dev/null || true
            chronyc tracking 2>/dev/null || true
        }
    )"

    if contains "$local_output" "active" &&
        grep -Eq "^[[:space:]]*server[[:space:]]+$ISP_IP([[:space:]]|$)" \
            <<< "$local_output"; then
        active=yes
    fi
    if grep -Eq "^\^\*[[:space:]]+$ISP_IP([[:space:]]|$)" <<< "$local_output"; then
        upstream=yes
        allow=yes
    fi
    if grep -Eq "Stratum[[:space:]]*:[[:space:]]*$expected_client_stratum([[:space:]]|$)" \
        <<< "$local_output"; then
        stratum=yes
    fi

    for state in "$active" "$stratum" "$upstream" "$allow"; do
        [[ "$state" == yes ]] && matched=$((matched + 1))
    done

    if [[ "$active$stratum$upstream$allow" == yesyesyesyes ]]; then
        set_result 6 1 "$title" "chronyd активен, stratum $NTP_STRATUM и доступ клиентам настроены"
    elif ((matched >= 3)); then
        set_result 6 0.5 "$title" "chronyd работает, одна настройка отличается"
    elif [[ "$remote_error" == yes ]]; then
        set_result 6 0 "$title" "SSH на ISP недоступен и HQ-CLI не синхронизирован с $ISP_IP"
    else
        set_result 6 0 "$title" "chronyd на ISP не работает или недоступен"
    fi
}

check_7_ansible() {
    local title="Ansible: четыре управляемых узла"
    local output
    local pong_count
    local remote_error=no

    output="$(linux_remote "$BR_SRV_IP" "
cd /etc/ansible 2>/dev/null || exit 1
ansible -m ping all 2>&1
" 2>/dev/null)" || true

    contains "$output" "__CHECK_REMOTE_ERROR__" && remote_error=yes
    pong_count="$(count_matches "$output" '\"ping\"[[:space:]]*:[[:space:]]*\"pong\"')"
    if ((pong_count >= 4)) &&
        ! grep -Eqi '(FAILED|UNREACHABLE|WARNING)' <<< "$output"; then
        set_result 7 1 "$title" "Все четыре узла ответили pong"
    elif ((pong_count >= 2)); then
        set_result 7 0.5 "$title" "Ответили pong: $pong_count узла"
    elif [[ "$remote_error" == yes ]]; then
        set_result 7 0 "$title" "BR-SRV недоступен проверяющему по SSH; ansible ping не выполнен"
    else
        set_result 7 0 "$title" "Ответили pong: $pong_count узлов"
    fi
}

check_8_docker() {
    local title="Контейнерное веб-приложение"
    local output
    local app_running=no
    local db_running=no
    local mapping_ok=no
    local any_mapping=no
    local database_ok=no
    local database_access=no
    local http_ok=no
    local any_http_ok=no
    local published_port
    local remote_error=no

    output="$(linux_remote "$BR_SRV_IP" "
docker inspect -f 'APP:{{.State.Running}} {{json .HostConfig.PortBindings}} {{range .Config.Env}}{{println .}}{{end}}' '$APP_CONTAINER' 2>/dev/null || true
docker inspect -f 'DB:{{.State.Running}} {{range .Config.Env}}{{println .}}{{end}}' '$DB_CONTAINER' 2>/dev/null || true
docker exec -e MYSQL_PWD='$APP_DB_PASSWORD' '$DB_CONTAINER' \
    mariadb -u '$APP_DB_USER' -Nse 'SELECT DATABASE();' '$APP_DB_NAME' 2>/dev/null &&
    echo DBACCESS:yes
" 2>/dev/null)" || true

    contains "$output" "__CHECK_REMOTE_ERROR__" && remote_error=yes
    contains "$output" "APP:true" && app_running=yes
    contains "$output" "DB:true" && db_running=yes
    contains "$output" "\"$APP_INTERNAL_PORT/tcp\"" &&
        contains "$output" "\"HostPort\":\"$APP_PORT\"" && mapping_ok=yes
    grep -Eq '"HostPort":"[0-9]+"' <<< "$output" && any_mapping=yes
    contains "$output" "DB_NAME=$APP_DB_NAME" &&
        contains "$output" "DB_USER=$APP_DB_USER" &&
        contains "$output" "DB_PASS=$APP_DB_PASSWORD" && database_ok=yes
    contains "$output" "DBACCESS:yes" && database_access=yes
    curl -fsS --connect-timeout 5 --max-time 15 \
        "http://$BR_SRV_IP:$APP_PORT/" >/dev/null 2>&1 && http_ok=yes
    if [[ "$http_ok" == no ]] &&
        curl -fsS --connect-timeout 5 --max-time 15 \
            "http://$BR_RTR_WAN_IP:$BR_APP_EXTERNAL_PORT/" >/dev/null 2>&1; then
        http_ok=yes
    fi
    published_port="$(
        grep -Eo '"HostPort":"[0-9]+"' <<< "$output" |
            head -n 1 |
            grep -Eo '[0-9]+' || true
    )"
    if [[ -n "$published_port" ]] &&
        curl -fsS --connect-timeout 5 --max-time 15 \
            "http://$BR_SRV_IP:$published_port/" >/dev/null 2>&1; then
        any_http_ok=yes
    fi

    if [[ "$app_running$db_running$mapping_ok$database_ok$database_access$http_ok" == yesyesyesyesyesyes ]]; then
        set_result 8 1 "$title" "Приложение и БД работают, опубликован порт $APP_PORT"
    elif [[ "$app_running$db_running$any_mapping$any_http_ok" == yesyesyesyes ]]; then
        set_result 8 0.5 "$title" "Контейнеры работают, но опубликованный порт отличается"
    elif [[ "$remote_error" == yes && "$http_ok" == yes ]]; then
        set_result 8 0.5 "$title" "Приложение отвечает, но BR-SRV недоступен по SSH для проверки контейнеров"
    else
        set_result 8 0 "$title" "Работающее контейнерное приложение не обнаружено"
    fi
}

check_9_web() {
    local title="Apache и MariaDB на HQ-SRV"
    local output
    local http_ok=no
    local active_count=0

    output="$(linux_remote "$HQ_SRV_IP" "
systemctl is-active httpd2 2>/dev/null || true
systemctl is-active mariadb 2>/dev/null || true
test -s /var/www/html/index.php && echo INDEX:yes
test -d /var/www/html/images && echo IMAGES:yes
test -s /var/www/html/logo.png && echo LOGO:yes
echo DB:\$(mariadb -u root -Nse \"SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$WEB_DB_NAME';\" 2>/dev/null)
echo USER:\$(mariadb -u root -Nse \"SELECT COUNT(*) FROM mysql.user WHERE User='$WEB_DB_USER';\" 2>/dev/null)
echo TABLES:\$(mariadb -u root -Nse \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$WEB_DB_NAME';\" 2>/dev/null)
MYSQL_PWD='$WEB_DB_PASSWORD' mariadb -u '$WEB_DB_USER' \
    -Nse 'SELECT DATABASE();' '$WEB_DB_NAME' 2>/dev/null &&
    echo DBACCESS:yes
" 2>/dev/null)" || true

    curl -fsS --connect-timeout 5 --max-time 15 \
        "http://$HQ_SRV_IP:$WEB_PORT/" >/dev/null 2>&1 && http_ok=yes
    active_count="$(count_matches "$output" '^active$')"

    if ((active_count >= 2)) &&
        contains "$output" "INDEX:yes" &&
        { contains "$output" "IMAGES:yes" || contains "$output" "LOGO:yes"; } &&
        [[ "$http_ok" == yes ]] &&
        contains "$output" "DB:1" &&
        grep -Eq '^USER:[1-9][0-9]*$' <<< "$output" &&
        grep -Eq '^TABLES:[1-9][0-9]*$' <<< "$output" &&
        contains "$output" "DBACCESS:yes"; then
        set_result 9 1 "$title" "Apache, MariaDB, приложение и база работают"
    else
        set_result 9 0 "$title" "Полная работоспособность веб-сервиса не подтверждена"
    fi
}

check_10_nat() {
    local title="Статическая трансляция портов"
    local hq_config="$1"
    local br_config="$2"
    local rules=0
    local hq_web=no
    local hq_ssh=no
    local br_app=no
    local br_ssh=no

    contains "$hq_config" "ip nat source static tcp $HQ_SRV_IP $WEB_PORT $HQ_RTR_WAN_IP $HQ_WEB_EXTERNAL_PORT" &&
        hq_web=yes
    contains "$hq_config" "ip nat source static tcp $HQ_SRV_IP $LINUX_SSH_PORT $HQ_RTR_WAN_IP $LINUX_SSH_PORT" &&
        hq_ssh=yes
    contains "$br_config" "ip nat source static tcp $BR_SRV_IP $APP_PORT $BR_RTR_WAN_IP $BR_APP_EXTERNAL_PORT" &&
        br_app=yes
    contains "$br_config" "ip nat source static tcp $BR_SRV_IP $LINUX_SSH_PORT $BR_RTR_WAN_IP $LINUX_SSH_PORT" &&
        br_ssh=yes

    curl -fsS --connect-timeout 3 --max-time 10 \
        "http://$HQ_RTR_WAN_IP:$HQ_WEB_EXTERNAL_PORT/" >/dev/null 2>&1 &&
        hq_web=yes
    curl -fsS --connect-timeout 3 --max-time 10 \
        "http://$BR_RTR_WAN_IP:$BR_APP_EXTERNAL_PORT/" >/dev/null 2>&1 &&
        br_app=yes
    ssh-keyscan -T 3 -p "$LINUX_SSH_PORT" "$HQ_RTR_WAN_IP" \
        >/dev/null 2>&1 && hq_ssh=yes
    ssh-keyscan -T 3 -p "$LINUX_SSH_PORT" "$BR_RTR_WAN_IP" \
        >/dev/null 2>&1 && br_ssh=yes

    for state in "$hq_web" "$hq_ssh" "$br_app" "$br_ssh"; do
        [[ "$state" == yes ]] && rules=$((rules + 1))
    done

    if ((rules == 4)); then
        set_result 10 1 "$title" "Все четыре трансляции подтверждены конфигурацией или подключением"
    elif ((rules == 3)); then
        set_result 10 0.5 "$title" "Не найдено одно правило NAT"
    else
        set_result 10 0 "$title" "Найдено правил NAT: $rules из 4"
    fi
}

check_11_proxy() {
    local title="Nginx reverse proxy на ISP"
    local output
    local web_code=000
    local docker_code=000
    local active=no
    local config_count=0
    local upstream_count=0
    local anonymous_web_code=000

    output="$(isp_remote "
systemctl is-active nginx 2>/dev/null || true
nginx -T 2>&1 || true
" 2>/dev/null)" || true

    contains "$output" "active" && active=yes
    contains "$output" "server_name $WEB_DOMAIN" && config_count=$((config_count + 1))
    contains "$output" "server_name $DOCKER_DOMAIN" && config_count=$((config_count + 1))
    contains "$output" "proxy_pass http://$HQ_RTR_WAN_IP:$HQ_WEB_EXTERNAL_PORT" &&
        upstream_count=$((upstream_count + 1))
    contains "$output" "proxy_pass http://$BR_RTR_WAN_IP:$BR_APP_EXTERNAL_PORT" &&
        upstream_count=$((upstream_count + 1))

    anonymous_web_code="$(web_status_code "http://$WEB_DOMAIN/")"
    web_code="$(
        web_status_code \
            "http://$WEB_DOMAIN/" \
            "$AUTH_USER:$AUTH_PASSWORD"
    )"
    docker_code="$(web_status_code "http://$DOCKER_DOMAIN/")"
    anonymous_web_code="${anonymous_web_code:-000}"
    web_code="${web_code:-000}"
    docker_code="${docker_code:-000}"

    if [[ "$web_code" =~ ^(2|3)[0-9][0-9]$ &&
        "$docker_code" =~ ^(2|3)[0-9][0-9]$ &&
        "$anonymous_web_code" == 401 ]]; then
        set_result 11 1 "$title" "Оба домена успешно проксируются через ISP"
    elif [[ "$active" == yes && "$config_count" -eq 2 && "$upstream_count" -eq 2 &&
        "$web_code" =~ ^(2|3)[0-9][0-9]$ &&
        "$docker_code" =~ ^(2|3)[0-9][0-9]$ ]]; then
        set_result 11 1 "$title" "Оба домена успешно проксируются"
    elif [[ "$active" == yes && "$config_count" -gt 0 ]] ||
        [[ "$web_code" =~ ^(2|3)[0-9][0-9]$ || "$docker_code" =~ ^(2|3)[0-9][0-9]$ ]]; then
        set_result 11 0.5 "$title" "Nginx настроен, но один из маршрутов не работает"
    else
        set_result 11 0 "$title" "Работающий reverse proxy не обнаружен"
    fi
}

check_12_auth() {
    local title="Web-based аутентификация"
    local anonymous_code
    local authenticated_code
    local password_ok=no

    anonymous_code="$(web_status_code "http://$WEB_DOMAIN/")"
    authenticated_code="$(
        web_status_code \
            "http://$WEB_DOMAIN/" \
            "$AUTH_USER:$AUTH_PASSWORD"
    )"
    anonymous_code="${anonymous_code:-000}"
    authenticated_code="${authenticated_code:-000}"

    isp_remote "
command -v htpasswd >/dev/null 2>&1 &&
htpasswd -vb /etc/nginx/.htpasswd '$AUTH_USER' '$AUTH_PASSWORD'
" >/dev/null 2>&1 && password_ok=yes

    if [[ "$anonymous_code" == 401 &&
        "$authenticated_code" =~ ^(2|3)[0-9][0-9]$ ]]; then
        password_ok=yes
    fi

    if [[ "$anonymous_code" == 401 &&
        "$authenticated_code" =~ ^(2|3)[0-9][0-9]$ &&
        "$password_ok" == yes ]]; then
        set_result 12 1 "$title" "Без пароля 401, корректные данные предоставляют доступ"
    else
        set_result 12 0 "$title" "Требуемая Basic Auth не подтверждена"
    fi
}

check_13_browser() {
    local title="Яндекс Браузер на HQ-CLI"

    if rpm -q yandex-browser-stable >/dev/null 2>&1 ||
        rpm -q yandex-browser-beta >/dev/null 2>&1 ||
        command -v yandex-browser >/dev/null 2>&1 ||
        command -v yandex-browser-stable >/dev/null 2>&1; then
        set_result 13 1 "$title" "Яндекс Браузер установлен"
    else
        set_result 13 0 "$title" "Яндекс Браузер не установлен"
    fi
}

print_results() {
    local number
    local score
    local total
    local title
    local detail
    local title_line
    local detail_line
    local -a title_lines
    local -a detail_lines
    local line_count
    local line_index
    local table_file="$TMP_DIR/results.tsv"
    local python_bin=""

    wrap_text() {
        local text="$1"
        local width="$2"

        printf '%s\n' "$text" |
            fold -s -w "$width"
    }

    printf '\n%sРезультаты проверки module_2%s\n\n' "$C_BOLD" "$C_RESET"
    printf '№\tБалл\tКритерий\tРезультат\n' > "$table_file"

    for number in $(seq 1 13); do
        score="${RESULT_SCORE[$number]:-0}"
        title="${RESULT_TITLE[$number]:-Не проверено}"
        detail="${RESULT_DETAIL[$number]:-Нет результата}"

        mapfile -t title_lines < <(wrap_text "$title" 40)
        mapfile -t detail_lines < <(wrap_text "$detail" 50)
        line_count="${#title_lines[@]}"
        ((${#detail_lines[@]} > line_count)) &&
            line_count="${#detail_lines[@]}"

        for ((line_index = 0; line_index < line_count; line_index++)); do
            title_line="${title_lines[$line_index]:-}"
            detail_line="${detail_lines[$line_index]:-}"
            if ((line_index == 0)); then
                printf '%s\t%s\t%s\t%s\n' \
                    "$number" "$score" "$title_line" "$detail_line" \
                    >> "$table_file"
            else
                printf '\t\t%s\t%s\n' "$title_line" "$detail_line" \
                    >> "$table_file"
            fi
        done
    done

    printf '14\tN/A\tОтчёт по ГОСТ\tНе проверяется скриптом\n' \
        >> "$table_file"

    if command -v python3 >/dev/null 2>&1; then
        python_bin=python3
    elif command -v python >/dev/null 2>&1; then
        python_bin=python
    fi

    if [[ -n "$python_bin" ]]; then
        TABLE_FILE="$table_file" \
            PYTHONUTF8=1 \
            PYTHONIOENCODING=utf-8 \
            "$python_bin" - <<'PY'
import csv
import os

with open(os.environ["TABLE_FILE"], encoding="utf-8", newline="") as source:
    rows = list(csv.reader(source, delimiter="\t"))

widths = [
    max(len(row[index]) for row in rows)
    for index in range(len(rows[0]))
]

for row_index, row in enumerate(rows):
    print(" | ".join(
        value.ljust(widths[index])
        for index, value in enumerate(row)
    ))
    if row_index == 0:
        print("-+-".join("-" * width for width in widths))
PY
    elif column --help 2>&1 | grep -q -- '--output-separator'; then
        column -t -s $'\t' -o ' | ' "$table_file"
    else
        column -t -s $'\t' "$table_file"
    fi

    total="$((TOTAL_HALF_POINTS / 2))"
    if ((TOTAL_HALF_POINTS % 2)); then
        total="${total}.5"
    fi

    printf '\n%sИтого: %s / 13 баллов%s\n' "$C_BOLD" "$total" "$C_RESET"
}

main() {
    local hq_router_config=""
    local br_router_config=""

    if [[ "${1:-}" == --self-test ]]; then
        for number in $(seq 1 13); do
            case $((number % 3)) in
                0) set_result "$number" 0 "Тестовый критерий $number" "Ошибка" ;;
                1) set_result "$number" 1 "Тестовый критерий $number" "Соответствует" ;;
                2) set_result "$number" 0.5 "Тестовый критерий $number" "Частично" ;;
            esac
        done
        print_results
        return
    fi

    [[ $EUID -eq 0 ]] || warn "Запуск не от root ограничит установку пакетов и проверку sudo"
    install_dependencies || warn "Some checks may be unavailable"
    select_linux_ssh_paths
    create_router_expect

    log "1/13 Samba DC"
    check_1_samba
    log "2/13 Domain users"
    check_2_users
    log "3/13 Restricted sudo"
    check_3_sudo
    log "4/13 RAID"
    check_4_raid
    log "5/13 NFS"
    check_5_nfs
    log "6/13 NTP on ISP"
    check_6_ntp
    log "7/13 Ansible"
    check_7_ansible
    log "8/13 Docker application"
    check_8_docker
    log "9/13 Apache application"
    check_9_web

    log "Reading EcoRouter configurations"
    hq_router_config="$(router_config "$HQ_RTR_SSH_HOST" || true)"
    br_router_config="$(router_config "$BR_RTR_SSH_HOST" || true)"

    log "10/13 Static NAT"
    check_10_nat "$hq_router_config" "$br_router_config"
    log "11/13 Reverse proxy"
    check_11_proxy
    log "12/13 Web authentication"
    check_12_auth
    log "13/13 Browser"
    check_13_browser

    print_results
}

main "$@"
