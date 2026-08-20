#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C

readonly SCRIPT_VERSION="1.2.0"
readonly MANAGED_BY="ss-libev-relay"
readonly STATE_SCHEMA=1
readonly DEFAULT_METHOD="aes-256-gcm"
readonly CONFIG_DIR="/etc/shadowsocks-libev"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly SERVICE_NAME="shadowsocks-libev.service"
readonly DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.d"
readonly DROPIN_FILE="${DROPIN_DIR}/10-ss-libev-relay.conf"
readonly STATE_DIR="/var/lib/ss-libev-relay"
readonly STATE_FILE="${STATE_DIR}/state.json"
readonly JOURNAL_FILE="${STATE_DIR}/transaction.json"
readonly BACKUP_ROOT="/var/backups/ss-libev-relay"
readonly LOCK_DIR="/run/ss-libev-relay"
readonly LOCK_FILE="${LOCK_DIR}/deploy.lock"
readonly FIREWALL_PREFIX="ss-libev-relay-v1"
readonly LEGACY_GROUP="shadowsocks-libev-config"
readonly CONFIG_GROUP="ss-libev-relay-config"

PORT=""
REQUESTED_PORT=""
PASSWORD=""
PASSWORD_FILE=""
METHOD=""
REQUESTED_METHOD=""
SERVER_ADDRESS=""
ALLOW_FROM=""
MIGRATE_FROM=""

PORT_WAS_SET=0
METHOD_WAS_SET=0
SERVER_WAS_SET=0
ALLOW_FROM_WAS_SET=0
ROTATE_PASSWORD=0
NO_FIREWALL=0
OPEN_FIREWALL=0
ADOPT_EXISTING=0
DRY_RUN=0
DEPRECATED_NON_INTERACTIVE=0

PACKAGE_INSTALLED_BY_SCRIPT=0
CONFIG_EXISTED_BEFORE_INSTALL=0
INSTALL_MASK_ACTIVE=0

SOURCE_KIND="fresh"
EXISTING_CONFIG=0
MANAGED_STATE=0
MIGRATING=0
LEGACY_CONFIG=""
LEGACY_SERVICE=""
LEGACY_DROPIN=""

OLD_FW_REQUESTED=""
OLD_FW_SOURCE=""
OLD_FW_PORT=""
OLD_FW_COMMENT=""
FW_REQUESTED="all"
FW_SOURCE=""
FW_RESULT=""
FW_COMMENT=""
FW_NEEDS_CHANGE=0
FW_OLD_RULE_COUNT=0
FW_NEW_RULE_COUNT=0
UFW_AVAILABLE=0
UFW_ACTIVE=0
UFW_MUTATED=0
FW_NEW_ATTEMPTED=0
FW_OLD_DELETE_ATTEMPTED=0

CONFIG_CHANGE=0
DROPIN_CHANGE=0
STATE_CHANGE=0
SERVICE_NEEDS_START=0
SERVICE_NEEDS_ENABLE=0
CONFIG_RELOAD_REQUIRED=0

DEFAULT_PREV_ACTIVE="inactive"
DEFAULT_PREV_ENABLED="disabled"
DEFAULT_PREV_ENABLE_PERSISTENT=0
DEFAULT_PREV_ENABLE_RUNTIME=0
LEGACY_PREV_ACTIVE="inactive"
LEGACY_PREV_ENABLED="disabled"
LEGACY_PREV_ENABLE_PERSISTENT=0
LEGACY_PREV_ENABLE_RUNTIME=0

TX_ACTIVE=0
SNAPSHOT_READY=0
TARGET_FILES_MUTATED=0
LEGACY_FILES_MUTATED=0
BACKUP_SESSION=""
WORK_DIR=""
SECRET_FILE=""
DESIRED_CONFIG=""
DESIRED_DROPIN=""
DESIRED_STATE=""
JOURNAL_TEMP=""
ATOMIC_TEMP=""

CONFIG_EXISTED=0
DROPIN_EXISTED=0
STATE_EXISTED=0
LEGACY_CONFIG_EXISTED=0
LEGACY_DROPIN_EXISTED=0
CONFIG_DIR_CREATED=0
DROPIN_DIR_CREATED=0
STATE_DIR_CREATED=0
CONFIG_GROUP_CREATED=0

usage() {
  cat <<'EOF'
用法：
  sudo bash setup-shadowsocks-libev.sh [选项]

作用：
  为另一台 3x-ui 主机部署一个稳定的 Shadowsocks-libev 中转。
  首次运行自动安装、生成端口和密码、放行 TCP+UDP，并打印 3x-ui
  出站 JSON；普通重跑保留原端口、密码和加密方式。

选项：
  --server <公网IPv4>       覆盖自动识别的 VPS 公网 IPv4
  --port <端口>             指定端口，范围 1024-65535
  --password-file <文件>    从普通文件第一行读取密码（16-128 位可见 ASCII）
  --rotate-password         为已受管服务生成新密码
  --method <加密方式>       aes-256-gcm（默认）或
                            chacha20-ietf-poly1305
  --allow-from <IPv4/CIDR>  新增限定该来源的 UFW TCP+UDP 规则
  --open-firewall           改为向全部 IPv4 来源放行 TCP+UDP
  --no-firewall             不新增规则；重跑时删除本脚本以前管理的规则
  --adopt-existing          显式接管已有默认 config.json
  --migrate-from <实例名>   显式迁移 v1.1 模板实例，例如 relay
  --dry-run                 仅校验并预览，不安装、不写文件、不管理服务
  -h, --help                显示帮助
  -V, --version             显示版本

示例：
  sudo bash setup-shadowsocks-libev.sh

  sudo bash setup-shadowsocks-libev.sh \
    --server 1.2.3.4 \
    --port 23456 \
    --method aes-256-gcm

  sudo bash setup-shadowsocks-libev.sh --rotate-password

重要说明：
  1. Shadowsocks 没有用户名；3x-ui 的“发送通过”保持空白。
  2. 本脚本固定管理 /etc/shadowsocks-libev/config.json 和
     shadowsocks-libev.service，只支持单节点、单密码。
  3. 本脚本使用发行版 shadowsocks-libev 包，暂不支持 2022-blake3-*；
     旧 aes-128-gcm 必须明确用 --method aes-256-gcm 才会迁移。
  4. 若系统已安装 UFW，默认写入该端口的 IPv4 TCP+UDP 规则；脚本
     不会自动安装/启用 UFW，也不会修改云厂商安全组。
  5. --allow-from 要求 UFW 默认入站策略为 DROP/REJECT，并检查常见
     用户规则冲突；它不审计自定义 nftables/iptables、UFW before.rules
     或云防火墙，因此不能单独证明系统不存在其他放行路径。
  6. HTTPS 证书、域名和 3x-ui 主机本机 IP 都不是此出站所需字段。
  7. 仅支持 systemd >= 247 的 Debian/Ubuntu（如 Debian 12/13、
     Ubuntu 22.04/24.04）。
EOF
}

info() {
  printf '[信息] %s\n' "$*"
}

warn() {
  printf '[警告] %s\n' "$*" >&2
}

die() {
  printf '[错误] %s\n' "$*" >&2
  exit 1
}

safe_remove_workdir() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    case "$WORK_DIR" in
      /run/ss-libev-relay.*|/tmp/ss-libev-relay.*)
        rm -rf -- "$WORK_DIR"
        ;;
      *)
        warn "拒绝清理非预期临时目录：$WORK_DIR"
        ;;
    esac
  fi
}

cleanup() {
  local exit_status=$?

  trap - EXIT INT TERM
  set +e

  if ((TX_ACTIVE == 1)); then
    rollback
  fi

  if ((INSTALL_MASK_ACTIVE == 1)); then
    systemctl unmask --runtime "$SERVICE_NAME" >/dev/null 2>&1 || true
    INSTALL_MASK_ACTIVE=0
  fi

  safe_remove_workdir
  if [[ -n "$JOURNAL_TEMP" && -f "$JOURNAL_TEMP" ]]; then
    rm -f -- "$JOURNAL_TEMP"
  fi
  if [[ -n "$ATOMIC_TEMP" && -e "$ATOMIC_TEMP" ]]; then
    rm -f -- "$ATOMIC_TEMP"
  fi
  exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while (($# > 0)); do
  case "$1" in
    --server)
      (($# >= 2)) || die "--server 缺少参数"
      SERVER_ADDRESS=$2
      SERVER_WAS_SET=1
      shift 2
      ;;
    --port)
      (($# >= 2)) || die "--port 缺少参数"
      REQUESTED_PORT=$2
      PORT_WAS_SET=1
      shift 2
      ;;
    --password-file)
      (($# >= 2)) || die "--password-file 缺少参数"
      PASSWORD_FILE=$2
      shift 2
      ;;
    --rotate-password)
      ROTATE_PASSWORD=1
      shift
      ;;
    --method)
      (($# >= 2)) || die "--method 缺少参数"
      REQUESTED_METHOD=$2
      METHOD_WAS_SET=1
      shift 2
      ;;
    --allow-from)
      (($# >= 2)) || die "--allow-from 缺少参数"
      ALLOW_FROM=$2
      ALLOW_FROM_WAS_SET=1
      shift 2
      ;;
    --no-firewall)
      NO_FIREWALL=1
      shift
      ;;
    --open-firewall)
      OPEN_FIREWALL=1
      shift
      ;;
    --adopt-existing)
      ADOPT_EXISTING=1
      shift
      ;;
    --migrate-from)
      (($# >= 2)) || die "--migrate-from 缺少参数"
      MIGRATE_FROM=$2
      shift 2
      ;;
    --non-interactive)
      DEPRECATED_NON_INTERACTIVE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --password)
      die "v1.2 不接受命令行明文密码；请使用 --password-file"
      ;;
    --name)
      die "v1.2 固定管理单个默认服务，不再支持 --name；迁移旧实例请用 --migrate-from"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -V|--version)
      printf '%s\n' "$SCRIPT_VERSION"
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

(($# == 0)) || die "存在无法识别的位置参数：$*"

[[ -z "$PASSWORD_FILE" || $ROTATE_PASSWORD -eq 0 ]] \
  || die "--password-file 与 --rotate-password 不能同时使用"
[[ $NO_FIREWALL -eq 0 || $ALLOW_FROM_WAS_SET -eq 0 ]] \
  || die "--no-firewall 与 --allow-from 不能同时使用"
[[ $OPEN_FIREWALL -eq 0 || $NO_FIREWALL -eq 0 ]] \
  || die "--open-firewall 与 --no-firewall 不能同时使用"
[[ $OPEN_FIREWALL -eq 0 || $ALLOW_FROM_WAS_SET -eq 0 ]] \
  || die "--open-firewall 与 --allow-from 不能同时使用"
[[ -z "$MIGRATE_FROM" || $ADOPT_EXISTING -eq 0 ]] \
  || die "--migrate-from 与 --adopt-existing 不能同时使用"

if ((DEPRECATED_NON_INTERACTIVE == 1)); then
  warn "--non-interactive 已无需使用：v1.2 默认全自动运行"
fi

require_root() {
  if ((DRY_RUN == 0)) && ((EUID != 0)); then
    die "请使用 root 运行，例如：sudo bash $0"
  fi
}

is_ipv4() {
  local ip=$1 a b c d extra

  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r a b c d extra <<<"$ip"
  [[ -z "${extra:-}" ]] || return 1

  local octet
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    [[ ${#octet} -eq 1 || ${octet:0:1} != "0" ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

is_public_ipv4() {
  local ip=$1 a b c d

  is_ipv4 "$ip" || return 1
  IFS=. read -r a b c d <<<"$ip"
  a=$((10#$a))
  b=$((10#$b))
  c=$((10#$c))
  d=$((10#$d))

  ((a != 0 && a != 10 && a != 127)) || return 1
  ((a < 224)) || return 1
  ! ((a == 100 && b >= 64 && b <= 127)) || return 1
  ! ((a == 169 && b == 254)) || return 1
  ! ((a == 172 && b >= 16 && b <= 31)) || return 1
  ! ((a == 192 && b == 0 && c == 0)) || return 1
  ! ((a == 192 && b == 0 && c == 2)) || return 1
  ! ((a == 192 && b == 88 && c == 99)) || return 1
  ! ((a == 192 && b == 168)) || return 1
  ! ((a == 198 && (b == 18 || b == 19))) || return 1
  ! ((a == 198 && b == 51 && c == 100)) || return 1
  ! ((a == 203 && b == 0 && c == 113)) || return 1
}

is_ipv4_cidr() {
  local value=$1 ip prefix

  if [[ "$value" == *"/"* ]]; then
    ip=${value%/*}
    prefix=${value#*\/}
    [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
    [[ ${#prefix} -eq 1 || ${prefix:0:1} != "0" ]] || return 1
    ((10#$prefix <= 32)) || return 1
  else
    ip=$value
  fi

  is_ipv4 "$ip"
}

canonicalize_ipv4_cidr() {
  local value=$1 ip prefix a b c d address mask network

  if [[ "$value" == *"/"* ]]; then
    ip=${value%/*}
    prefix=$((10#${value#*/}))
  else
    printf '%s\n' "$value"
    return 0
  fi

  if ((prefix == 32)); then
    printf '%s\n' "$ip"
    return 0
  fi

  IFS=. read -r a b c d <<<"$ip"
  address=$(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
  if ((prefix == 0)); then
    mask=0
  else
    mask=$(((0xffffffff << (32 - prefix)) & 0xffffffff))
  fi
  network=$((address & mask))
  printf '%d.%d.%d.%d/%d\n' \
    "$(((network >> 24) & 255))" \
    "$(((network >> 16) & 255))" \
    "$(((network >> 8) & 255))" \
    "$((network & 255))" \
    "$prefix"
}

validate_instance_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

validate_port() {
  local value=$1

  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  ((${#value} <= 5)) || return 1
  [[ ${value:0:1} != "0" ]] || return 1
  ((10#$value >= 1024 && 10#$value <= 65535))
}

validate_requested_method() {
  case "$1" in
    aes-256-gcm|chacha20-ietf-poly1305) return 0 ;;
    aes-128-gcm)
      die "当前 3x-ui 前端不列出 aes-128-gcm；请使用 aes-256-gcm"
      ;;
    2022-blake3-*)
      die "APT 发行版 shadowsocks-libev 暂不支持 SS2022；请使用 aes-256-gcm"
      ;;
    *)
      die "不支持的加密方式：$1"
      ;;
  esac
}

validate_existing_method() {
  case "$1" in
    aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305) return 0 ;;
    *) die "现有配置的加密方式不在可迁移范围：$1" ;;
  esac
}

validate_password() {
  [[ "$PASSWORD" =~ ^[[:graph:]]{16,128}$ ]] \
    || die "密码必须是 16-128 位可见 ASCII 字符，且不能包含空格或控制字符"
}

validate_early_options() {
  if ((PORT_WAS_SET == 1)); then
    validate_port "$REQUESTED_PORT" \
      || die "端口必须是 1024-65535 的十进制整数"
    REQUESTED_PORT=$((10#$REQUESTED_PORT))
  fi

  if ((METHOD_WAS_SET == 1)); then
    validate_requested_method "$REQUESTED_METHOD"
  fi

  if ((SERVER_WAS_SET == 1)); then
    is_public_ipv4 "$SERVER_ADDRESS" \
      || die "--server 只接受可路由的公网 IPv4，不接受域名、IPv6、私网或保留地址"
  fi

  if ((ALLOW_FROM_WAS_SET == 1)); then
    is_ipv4_cidr "$ALLOW_FROM" \
      || die "--allow-from 只接受合法 IPv4 或 IPv4 CIDR（前缀 0-32）"
    ALLOW_FROM=$(canonicalize_ipv4_cidr "$ALLOW_FROM")
    [[ "$ALLOW_FROM" != "0.0.0.0/0" ]] \
      || die "--allow-from 0.0.0.0/0 并未限制来源；请省略该选项"
  fi

  if [[ -n "$MIGRATE_FROM" ]]; then
    validate_instance_name "$MIGRATE_FROM" \
      || die "迁移实例名只能包含字母、数字、下划线和连字符"
  fi

  if ((DRY_RUN == 1)) && [[ -n "$MIGRATE_FROM" || $ADOPT_EXISTING -eq 1 ]]; then
    die "--dry-run 不读取系统现有实例，不能与 --migrate-from/--adopt-existing 同用"
  fi
}

check_platform() {
  local os_id="" os_like="" systemd_version=""

  command -v apt-get >/dev/null 2>&1 \
    || die "仅支持使用 APT 的 Debian/Ubuntu 系统"
  command -v systemctl >/dev/null 2>&1 \
    || die "系统没有 systemctl，无法管理服务"
  [[ -d /run/systemd/system ]] \
    || die "当前系统不是由 systemd 作为 PID 1 管理"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id=${ID:-}
    os_like=${ID_LIKE:-}
    case " ${os_id} ${os_like} " in
      *debian*|*ubuntu*) ;;
      *) die "仅支持 Debian/Ubuntu，当前系统：${PRETTY_NAME:-未知}" ;;
    esac
  fi

  systemd_version=$(systemctl --version | awk 'NR == 1 {print $2}')
  [[ "$systemd_version" =~ ^[0-9]+$ ]] \
    || die "无法识别 systemd 版本"
  ((systemd_version >= 247)) \
    || die "本脚本的受支持基线是 systemd >= 247；当前版本：$systemd_version"
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null \
    | grep -q '^install ok installed$'
}

install_dependencies() {
  local -a packages=()
  local package load_state

  [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]] \
    && CONFIG_EXISTED_BEFORE_INSTALL=1

  if ! package_installed shadowsocks-libev; then
    load_state=$(systemctl show -p LoadState --value "$SERVICE_NAME" 2>/dev/null || true)
    if [[ -n "$load_state" && "$load_state" != "not-found" ]]; then
      die "APT 未登记 shadowsocks-libev，但系统已有同名 unit（$load_state）；为避免停掉第三方服务，请先人工处理"
    fi
    if ((CONFIG_EXISTED_BEFORE_INSTALL == 1)); then
      die "APT 未登记 shadowsocks-libev，但 $CONFIG_FILE 已存在；请先备份并人工确认来源"
    fi
    packages+=(shadowsocks-libev)
    PACKAGE_INSTALLED_BY_SCRIPT=1
  fi
  command -v openssl >/dev/null 2>&1 || packages+=(openssl)
  command -v ss >/dev/null 2>&1 || packages+=(iproute2)
  command -v curl >/dev/null 2>&1 || packages+=(curl ca-certificates)
  command -v jq >/dev/null 2>&1 || packages+=(jq)

  if ((${#packages[@]} > 0)); then
    if ((PACKAGE_INSTALLED_BY_SCRIPT == 1)); then
      systemctl mask --runtime "$SERVICE_NAME" >/dev/null
      INSTALL_MASK_ACTIVE=1
    fi

    info "更新 APT 索引并安装缺少的软件包"
    apt-get update

    if ((PACKAGE_INSTALLED_BY_SCRIPT == 1)) \
      && ! apt-cache show shadowsocks-libev >/dev/null 2>&1; then
      die "APT 源中没有 shadowsocks-libev；Ubuntu 请先确认 Universe 仓库已启用"
    fi

    DEBIAN_FRONTEND=noninteractive \
      apt-get install -y --no-install-recommends "${packages[@]}"

    if ((INSTALL_MASK_ACTIVE == 1)); then
      systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
      systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
      systemctl unmask --runtime "$SERVICE_NAME" >/dev/null
      INSTALL_MASK_ACTIVE=0
    fi
  fi

  for package in /usr/bin/ss-server openssl ss curl jq sync; do
    if [[ "$package" == /* ]]; then
      [[ -x "$package" ]] || die "安装后仍找不到：$package"
    else
      command -v "$package" >/dev/null 2>&1 \
        || die "安装后仍找不到：$package"
    fi
  done

  systemctl cat "$SERVICE_NAME" >/dev/null 2>&1 \
    || die "软件包未提供 $SERVICE_NAME"
}

validate_unit_layout() {
  local fragment path mask_valid=0 vendor_valid=0
  local -a dropin_roots=(
    "/etc/systemd/system/${SERVICE_NAME}.d"
    "/run/systemd/system/${SERVICE_NAME}.d"
  )

  fragment=$(systemctl show -p FragmentPath --value "$SERVICE_NAME")
  case "$fragment" in
    /lib/systemd/system/shadowsocks-libev.service|\
    /usr/lib/systemd/system/shadowsocks-libev.service)
      ;;
    /dev/null|\
    /etc/systemd/system/shadowsocks-libev.service|\
    /run/systemd/system/shadowsocks-libev.service)
      for path in \
        "/etc/systemd/system/${SERVICE_NAME}" \
        "/run/systemd/system/${SERVICE_NAME}"; do
        if [[ -L "$path" && "$(readlink "$path")" == "/dev/null" ]]; then
          mask_valid=1
        fi
      done
      for path in \
        /lib/systemd/system/shadowsocks-libev.service \
        /usr/lib/systemd/system/shadowsocks-libev.service; do
        [[ -f "$path" && ! -L "$path" ]] && vendor_valid=1
      done
      ((mask_valid == 1 && vendor_valid == 1)) \
        || die "默认服务的 mask 或发行版 unit 不完整，拒绝猜测"
      ;;
    *)
      die "默认服务 unit 不是发行版文件，拒绝覆盖外部实现：$fragment"
      ;;
  esac

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$path" == "$DROPIN_FILE" ]] \
      || die "发现其他 $SERVICE_NAME drop-in，无法保证最终安全属性：$path"
  done < <(
    systemctl show -p DropInPaths --value "$SERVICE_NAME" \
      | tr ' ' '\n'
  )

  for path in "${dropin_roots[@]}"; do
    [[ -d "$path" ]] || continue
    while IFS= read -r fragment; do
      [[ "$fragment" == "$DROPIN_FILE" ]] \
        || die "发现其他 $SERVICE_NAME drop-in，无法保证最终安全属性：$fragment"
    done < <(find "$path" -mindepth 1 -maxdepth 1 -print)
  done
}

verify_effective_unit() {
  local dynamic_user groups environment_files exec_start argv
  local service_user service_group exec_start_pre exec_start_post

  validate_unit_layout
  dynamic_user=$(systemctl show -p DynamicUser --value "$SERVICE_NAME")
  groups=$(systemctl show -p SupplementaryGroups --value "$SERVICE_NAME")
  environment_files=$(systemctl show -p EnvironmentFiles --value "$SERVICE_NAME")
  exec_start=$(systemctl show -p ExecStart --value "$SERVICE_NAME")
  service_user=$(systemctl show -p User --value "$SERVICE_NAME")
  service_group=$(systemctl show -p Group --value "$SERVICE_NAME")
  exec_start_pre=$(systemctl show -p ExecStartPre --value "$SERVICE_NAME")
  exec_start_post=$(systemctl show -p ExecStartPost --value "$SERVICE_NAME")
  argv=${exec_start#*argv\[\]=}
  argv=${argv%% ; ignore_errors=*}

  [[ "$dynamic_user" == "yes" ]] \
    || die "最终 unit 未保留 DynamicUser=yes"
  [[ "$service_user" == "shadowsocks-libev" \
    && "$service_group" == "shadowsocks-libev" ]] \
    || die "最终 unit 的 User/Group 不符合发行版非 root 服务身份"
  [[ "$groups" == "$CONFIG_GROUP" ]] \
    || die "最终 unit 的 SupplementaryGroups 不等于专用配置组"
  [[ -z "$environment_files" ]] \
    || die "最终 unit 仍加载外部 EnvironmentFile：$environment_files"
  [[ -z "$exec_start_pre" && -z "$exec_start_post" ]] \
    || die "最终 unit 含有非预期的 ExecStartPre/ExecStartPost"
  [[ "$argv" == "/usr/bin/ss-server -c $CONFIG_FILE" ]] \
    || die "最终 unit 的 ExecStart 不符合预期：$argv"
}

create_workdir() {
  if [[ -d /run && -w /run ]]; then
    WORK_DIR=$(mktemp -d /run/ss-libev-relay.XXXXXX)
  else
    WORK_DIR=$(mktemp -d /tmp/ss-libev-relay.XXXXXX)
  fi
  chmod 0700 "$WORK_DIR"
  SECRET_FILE="${WORK_DIR}/password"
  DESIRED_CONFIG="${WORK_DIR}/config.json"
  DESIRED_DROPIN="${WORK_DIR}/dropin.conf"
  DESIRED_STATE="${WORK_DIR}/state.json"
}

read_password_file() {
  [[ -f "$PASSWORD_FILE" && ! -L "$PASSWORD_FILE" ]] \
    || die "密码文件必须是非符号链接的普通文件：$PASSWORD_FILE"
  [[ -r "$PASSWORD_FILE" ]] || die "无法读取密码文件：$PASSWORD_FILE"

  PASSWORD=""
  IFS= read -r PASSWORD <"$PASSWORD_FILE" || true
  PASSWORD=${PASSWORD%$'\r'}
  [[ -n "$PASSWORD" ]] || die "密码文件第一行为空"
}

random_password() {
  openssl rand -hex 24
}

port_listening() {
  local protocol=$1 port=$2 flag

  case "$protocol" in
    tcp) flag=-lnt ;;
    udp) flag=-lnu ;;
    *) return 1 ;;
  esac

  [[ -n "$(ss -H "$flag" "sport = :${port}" 2>/dev/null || true)" ]]
}

port_in_use() {
  port_listening tcp "$1" || port_listening udp "$1"
}

random_port() {
  local attempt random_hex candidate

  for ((attempt = 0; attempt < 64; attempt++)); do
    random_hex=$(openssl rand -hex 2)
    candidate=$((16#$random_hex % 40001 + 20000))
    if ! port_in_use "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  die "无法自动找到空闲端口，请使用 --port 指定"
}

detect_server_address() {
  local endpoint detected
  local -a endpoints=(
    "https://api.ipify.org"
    "https://ifconfig.me/ip"
    "https://icanhazip.com"
  )

  for endpoint in "${endpoints[@]}"; do
    detected=$(curl --noproxy '*' -4fsS \
      --connect-timeout 3 --max-time 5 "$endpoint" 2>/dev/null || true)
    detected=${detected//$'\r'/}
    detected=${detected//$'\n'/}
    if is_public_ipv4 "$detected"; then
      printf '%s\n' "$detected"
      return 0
    fi
  done

  return 1
}

assert_secure_regular_file() {
  local file=$1 description=$2 uid mode

  [[ -f "$file" && ! -L "$file" ]] \
    || die "$description 必须是非符号链接的普通文件：$file"
  uid=$(stat -c '%u' "$file")
  mode=$(stat -c '%a' "$file")
  [[ "$uid" == "0" ]] \
    || die "$description 必须由 root 拥有：$file"
  (( (8#$mode & 0022) == 0 )) \
    || die "$description 允许组或其他用户写入，拒绝信任其内容：$file（权限 $mode）"
}

is_stock_package_config() {
  [[ -f "$CONFIG_FILE" ]] || return 1
  jq -e '
    (keys | sort) ==
      ["local_port", "method", "mode", "password", "server",
       "server_port", "timeout"] and
    (.server == ["::1", "127.0.0.1"] or
     .server == ["127.0.0.1", "::1"]) and
    .server_port == 8388 and
    .local_port == 1080 and
    (.password == "barfoo!" or
     (.password | type == "string" and test("^[A-Za-z0-9]{12}$"))) and
    .timeout == 86400 and
    .method == "chacha20-ietf-poly1305" and
    .mode == "tcp_and_udp"
  ' "$CONFIG_FILE" >/dev/null 2>&1
}

load_config_values() {
  local file=$1 loaded_port loaded_password loaded_method

  assert_secure_regular_file "$file" "Shadowsocks 配置"
  jq -e 'type == "object"' "$file" >/dev/null \
    || die "配置不是有效 JSON 对象：$file"

  loaded_port=$(jq -r '.server_port // empty' "$file")
  loaded_password=$(jq -r '.password // empty' "$file")
  loaded_method=$(jq -r '.method // empty' "$file")

  validate_port "$loaded_port" \
    || die "现有配置 server_port 无效：$file"
  PASSWORD=$loaded_password
  validate_password
  validate_existing_method "$loaded_method"

  PORT=$((10#$loaded_port))
  METHOD=$loaded_method
  EXISTING_CONFIG=1
}

load_managed_state() {
  local checksum actual_checksum config_checksum actual_config_checksum

  assert_secure_regular_file "$STATE_FILE" "状态文件"
  jq -e \
    --arg managed_by "$MANAGED_BY" \
    --argjson schema "$STATE_SCHEMA" \
    '.managed_by == $managed_by and .schema_version == $schema' \
    "$STATE_FILE" >/dev/null \
    || die "状态文件不是本脚本支持的格式：$STATE_FILE"

  assert_secure_regular_file "$CONFIG_FILE" "受管 Shadowsocks 配置"
  config_checksum=$(jq -r '.config_sha256 // empty' "$STATE_FILE")
  actual_config_checksum=$(sha256_file "$CONFIG_FILE")
  if [[ ! "$config_checksum" =~ ^[0-9a-f]{64}$ \
    || "$actual_config_checksum" != "$config_checksum" ]]; then
    CONFIG_RELOAD_REQUIRED=1
    warn "受管配置与上次已应用校验值不同；本次将强制重启服务并更新状态"
  fi

  checksum=$(jq -r '.dropin_sha256 // empty' "$STATE_FILE")
  if [[ -e "$DROPIN_FILE" || -L "$DROPIN_FILE" ]]; then
    assert_secure_regular_file "$DROPIN_FILE" "受管 systemd drop-in"
    actual_checksum=$(sha256sum "$DROPIN_FILE" | awk '{print $1}')
    [[ -n "$checksum" && "$actual_checksum" == "$checksum" ]] \
      || die "受管 systemd drop-in 已被外部修改；请先审查：$DROPIN_FILE"
  fi

  MANAGED_STATE=1
  SOURCE_KIND=$(jq -r '.source_kind // "managed"' "$STATE_FILE")
  MIGRATE_FROM=$(jq -r '.migrated_from // empty' "$STATE_FILE")
  load_config_values "$CONFIG_FILE"

  if ((SERVER_WAS_SET == 0)); then
    SERVER_ADDRESS=$(jq -r '.server_address // empty' "$STATE_FILE")
  fi

  OLD_FW_REQUESTED=$(jq -r '.firewall.requested // "all"' "$STATE_FILE")
  OLD_FW_SOURCE=$(jq -r '.firewall.source // empty' "$STATE_FILE")
  OLD_FW_PORT=$(jq -r '.firewall.port // empty' "$STATE_FILE")
  OLD_FW_COMMENT=$(jq -r '.firewall.comment // empty' "$STATE_FILE")

  case "$OLD_FW_REQUESTED" in
    all|restricted|disabled) ;;
    *) die "状态文件中的旧防火墙模式无效：$OLD_FW_REQUESTED" ;;
  esac
  if [[ -n "$OLD_FW_COMMENT" ]]; then
    [[ "$OLD_FW_REQUESTED" != "disabled" ]] \
      || die "状态文件把已禁用防火墙与受管规则标记同时记录，拒绝猜测"
    [[ "$OLD_FW_COMMENT" =~ ^${FIREWALL_PREFIX}-[0-9]{4,5}-[0-9a-f]{6}$ ]] \
      || die "状态文件中的 UFW 规则标记不属于本脚本"
    validate_port "$OLD_FW_PORT" \
      || die "状态文件中的旧 UFW 端口无效"
    if [[ "$OLD_FW_REQUESTED" == "restricted" ]]; then
      is_ipv4_cidr "$OLD_FW_SOURCE" \
        || die "状态文件中的旧 UFW 来源无效"
      OLD_FW_SOURCE=$(canonicalize_ipv4_cidr "$OLD_FW_SOURCE")
      [[ "$OLD_FW_SOURCE" != "0.0.0.0/0" ]] \
        || die "状态文件中的旧 UFW 来源没有实际限制"
    fi
  fi
}

legacy_dropin_has_v1_1_signature() {
  local file=$1 normalized

  [[ -f "$file" && ! -L "$file" ]] || return 1
  normalized=$(awk 'NF {print}' "$file")
  [[ "$normalized" == $'[Service]\n'"SupplementaryGroups=${LEGACY_GROUP}" ]]
}

validate_legacy_unit_layout() {
  local fragment path
  local -a dropin_roots=(
    "/etc/systemd/system/${LEGACY_SERVICE}.d"
    "/run/systemd/system/${LEGACY_SERVICE}.d"
  )

  fragment=$(systemctl show -p FragmentPath --value "$LEGACY_SERVICE")
  case "$fragment" in
    /lib/systemd/system/shadowsocks-libev-server@.service|\
    /usr/lib/systemd/system/shadowsocks-libev-server@.service)
      ;;
    *)
      die "旧实例不是发行版 shadowsocks-libev 模板 unit：$fragment"
      ;;
  esac

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$path" == "$LEGACY_DROPIN" ]] \
      || die "旧实例存在额外 systemd drop-in，拒绝迁移：$path"
  done < <(
    systemctl show -p DropInPaths --value "$LEGACY_SERVICE" \
      | tr ' ' '\n'
  )

  for path in "${dropin_roots[@]}"; do
    [[ -d "$path" ]] || continue
    while IFS= read -r fragment; do
      [[ "$fragment" == "$LEGACY_DROPIN" ]] \
        || die "旧实例磁盘上存在额外 systemd drop-in，拒绝迁移：$fragment"
    done < <(find "$path" -mindepth 1 -maxdepth 1 -print)
  done
}

prepare_migration() {
  LEGACY_CONFIG="${CONFIG_DIR}/${MIGRATE_FROM}.json"
  LEGACY_SERVICE="shadowsocks-libev-server@${MIGRATE_FROM}.service"
  LEGACY_DROPIN="/etc/systemd/system/${LEGACY_SERVICE}.d/10-ss-config-access.conf"

  assert_secure_regular_file "$LEGACY_CONFIG" "v1.1 配置"
  systemctl cat "$LEGACY_SERVICE" >/dev/null 2>&1 \
    || die "找不到可迁移的模板服务：$LEGACY_SERVICE"
  assert_secure_regular_file "$LEGACY_DROPIN" "v1.1 systemd drop-in"
  legacy_dropin_has_v1_1_signature "$LEGACY_DROPIN" \
    || die "旧实例不符合 v1.1 签名，拒绝自动接管：$LEGACY_DROPIN"
  validate_legacy_unit_layout

  if [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]]; then
    assert_secure_regular_file "$CONFIG_FILE" "默认 Shadowsocks 配置"
    if ((PACKAGE_INSTALLED_BY_SCRIPT == 1 && CONFIG_EXISTED_BEFORE_INSTALL == 0)); then
      :
    elif is_stock_package_config; then
      :
    else
      die "默认 config.json 已有非示例配置；不能同时迁移旧实例"
    fi
  fi

  SOURCE_KIND="migration"
  MIGRATING=1
  CONFIG_RELOAD_REQUIRED=1
  load_config_values "$LEGACY_CONFIG"
}

legacy_candidates_exist() {
  local candidate
  shopt -s nullglob
  for candidate in /etc/systemd/system/shadowsocks-libev-server@*.service.d/10-ss-config-access.conf; do
    if legacy_dropin_has_v1_1_signature "$candidate"; then
      warn "发现 v1.1 实例标记：$candidate"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

discover_source() {
  if [[ -e "$STATE_FILE" || -L "$STATE_FILE" ]]; then
    [[ -z "$MIGRATE_FROM" ]] \
      || die "服务已经由 v1.2 管理，不能再次指定 --migrate-from"
    ((ADOPT_EXISTING == 0)) \
      || die "服务已经由 v1.2 管理，不需要 --adopt-existing"
    load_managed_state
    return
  fi

  if [[ -n "$MIGRATE_FROM" ]]; then
    prepare_migration
    return
  fi

  if legacy_candidates_exist; then
    die "检测到 v1.1 模板实例；请明确使用 --migrate-from <实例名>，脚本不会猜测"
  fi

  if [[ -e "$DROPIN_FILE" || -L "$DROPIN_FILE" ]]; then
    die "发现无状态文件对应的 systemd drop-in，拒绝覆盖：$DROPIN_FILE"
  fi

  if [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]]; then
    assert_secure_regular_file "$CONFIG_FILE" "默认 Shadowsocks 配置"

    if ((PACKAGE_INSTALLED_BY_SCRIPT == 1 && CONFIG_EXISTED_BEFORE_INSTALL == 0)); then
      SOURCE_KIND="fresh"
      return
    fi

    if is_stock_package_config; then
      SOURCE_KIND="fresh"
      return
    fi

    ((ADOPT_EXISTING == 1)) \
      || die "发现未受管的默认配置；确认接管请重新运行并加 --adopt-existing"
    SOURCE_KIND="adopted"
    CONFIG_RELOAD_REQUIRED=1
    load_config_values "$CONFIG_FILE"
    return
  fi

  ((ADOPT_EXISTING == 0)) \
    || die "--adopt-existing 已指定，但默认配置不存在：$CONFIG_FILE"
  SOURCE_KIND="fresh"
}

assert_secure_directory() {
  local directory=$1 uid mode

  [[ -d "$directory" && ! -L "$directory" ]] \
    || die "路径不是安全的普通目录：$directory"
  uid=$(stat -c '%u' "$directory")
  mode=$(stat -c '%a' "$directory")
  [[ "$uid" == "0" ]] || die "目录必须由 root 拥有：$directory"
  (( (8#$mode & 0022) == 0 )) \
    || die "目录不能允许组或其他用户写入：$directory（权限 $mode）"
}

assert_config_directory_traversable() {
  local mode group

  [[ -d "$CONFIG_DIR" && ! -L "$CONFIG_DIR" ]] || return 0
  mode=$(stat -c '%a' "$CONFIG_DIR")
  group=$(stat -c '%G' "$CONFIG_DIR")

  if (( (8#$mode & 0001) != 0 )); then
    return 0
  fi
  if [[ "$group" == "$CONFIG_GROUP" ]] && (( (8#$mode & 0010) != 0 )); then
    return 0
  fi
  die "$CONFIG_DIR 不允许服务专用组穿越；请审查后设为 root:root 0755 或 root:$CONFIG_GROUP 0750"
}

preflight_existing_directories() {
  local directory
  for directory in "$CONFIG_DIR" "$DROPIN_DIR" "$STATE_DIR"; do
    if [[ -e "$directory" || -L "$directory" ]]; then
      assert_secure_directory "$directory"
    fi
  done
  assert_config_directory_traversable
}

cleanup_stale_managed_temps() {
  local file uid mode
  local -a stale_files=()

  shopt -s nullglob
  stale_files+=(
    "$CONFIG_DIR"/.ss-libev-relay.*
    "$DROPIN_DIR"/.ss-libev-relay.*
    "$STATE_DIR"/.ss-libev-relay.*
    "$STATE_DIR"/.transaction.*
  )
  shopt -u nullglob

  for file in "${stale_files[@]}"; do
    [[ -f "$file" && ! -L "$file" ]] \
      || die "发现非普通的受管临时路径，拒绝删除：$file"
    uid=$(stat -c '%u' "$file")
    mode=$(stat -c '%a' "$file")
    [[ "$uid" == "0" && $((8#$mode & 0022)) -eq 0 ]] \
      || die "受管临时文件所有权或权限异常，拒绝删除：$file"
    rm -f -- "$file"
  done
}

validate_existing_config_group() {
  local entry gid members

  if ! entry=$(getent group "$CONFIG_GROUP"); then
    return 0
  fi

  gid=$(printf '%s\n' "$entry" | awk -F: '{print $3}')
  members=$(printf '%s\n' "$entry" | awk -F: '{print $4}')
  [[ -z "$members" ]] \
    || die "专用配置组已有显式成员，拒绝向其授予密码读取权：$CONFIG_GROUP"

  if getent passwd \
    | awk -F: -v gid="$gid" '$4 == gid {found=1} END {exit !found}'; then
    die "已有系统账号把 $CONFIG_GROUP 作为主组，拒绝复用"
  fi
}

ensure_config_group() {
  validate_existing_config_group
  if ! getent group "$CONFIG_GROUP" >/dev/null 2>&1; then
    command -v groupadd >/dev/null 2>&1 \
      || die "系统缺少 groupadd，无法创建专用配置组"
    groupadd --system "$CONFIG_GROUP"
    CONFIG_GROUP_CREATED=1
  fi
}

resolve_inputs() {
  local detected=""

  if ((ROTATE_PASSWORD == 1 && EXISTING_CONFIG == 0)); then
    die "--rotate-password 仅用于已有受管、接管或迁移配置；首次部署会自动生成密码"
  fi

  if ((EXISTING_CONFIG == 0)); then
    if ((PORT_WAS_SET == 1)); then
      PORT=$REQUESTED_PORT
    else
      PORT=$(random_port)
    fi
    if ((METHOD_WAS_SET == 1)); then
      METHOD=$REQUESTED_METHOD
    else
      METHOD=$DEFAULT_METHOD
    fi
    if [[ -n "$PASSWORD_FILE" ]]; then
      read_password_file
    else
      PASSWORD=$(random_password)
    fi
  else
    if ((PORT_WAS_SET == 1)); then
      PORT=$REQUESTED_PORT
    fi
    if ((METHOD_WAS_SET == 1)); then
      METHOD=$REQUESTED_METHOD
    fi
    if [[ -n "$PASSWORD_FILE" ]]; then
      read_password_file
    elif ((ROTATE_PASSWORD == 1)); then
      PASSWORD=$(random_password)
    fi
  fi

  validate_port "$PORT" || die "端口必须在 1024-65535 之间"
  PORT=$((10#$PORT))
  if ((METHOD_WAS_SET == 1)); then
    validate_requested_method "$METHOD"
  else
    validate_existing_method "$METHOD"
    [[ "$METHOD" != "aes-128-gcm" ]] \
      || die "现有配置使用 aes-128-gcm；当前 3x-ui 下拉列表不提供它。请明确加 --method aes-256-gcm 后再迁移，脚本不会在普通重跑时静默断开旧客户端"
  fi
  validate_password

  if ((SERVER_WAS_SET == 0)); then
    if [[ -n "$SERVER_ADDRESS" ]] && is_public_ipv4 "$SERVER_ADDRESS"; then
      :
    else
      detected=$(detect_server_address || true)
      [[ -n "$detected" ]] \
        || die "无法自动识别公网 IPv4，请使用 --server 指定"
      SERVER_ADDRESS=$detected
      info "已自动识别 VPS 公网 IPv4：$SERVER_ADDRESS"
    fi
  fi
  is_public_ipv4 "$SERVER_ADDRESS" \
    || die "服务器地址必须是可路由的公网 IPv4"

  if ((NO_FIREWALL == 1)); then
    FW_REQUESTED="disabled"
    FW_SOURCE=""
  elif ((ALLOW_FROM_WAS_SET == 1)); then
    FW_REQUESTED="restricted"
    FW_SOURCE=$ALLOW_FROM
  elif ((OPEN_FIREWALL == 1)); then
    FW_REQUESTED="all"
    FW_SOURCE=""
  elif ((MANAGED_STATE == 1)); then
    FW_REQUESTED=${OLD_FW_REQUESTED:-all}
    FW_SOURCE=$OLD_FW_SOURCE
  else
    FW_REQUESTED="all"
    FW_SOURCE=""
  fi

  case "$FW_REQUESTED" in
    all|disabled) FW_SOURCE="" ;;
    restricted)
      is_ipv4_cidr "$FW_SOURCE" \
        || die "状态文件中的 UFW 来源无效，请显式使用 --allow-from 或 --no-firewall 修正"
      ;;
    *) die "状态文件中的防火墙模式无效：$FW_REQUESTED" ;;
  esac
}

write_secret_file() {
  printf '%s' "$PASSWORD" >"$SECRET_FILE"
  chmod 0600 "$SECRET_FILE"
}

render_config() {
  jq -n \
    --argjson port "$PORT" \
    --rawfile password "$SECRET_FILE" \
    --arg method "$METHOD" \
    '{
      server: "0.0.0.0",
      server_port: $port,
      password: $password,
      timeout: 300,
      method: $method,
      mode: "tcp_and_udp",
      fast_open: false,
      no_delay: true
    }'
}

render_dropin() {
  cat <<'EOF'
# Managed by ss-libev-relay v1.2
[Service]
EnvironmentFile=
ExecStart=
SupplementaryGroups=
SupplementaryGroups=ss-libev-relay-config
ExecStart=/usr/bin/ss-server -c /etc/shadowsocks-libev/config.json
EOF
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

durable_sync() {
  sync -f "$1"
}

render_state() {
  local dropin_hash=$1 config_hash=$2

  jq -n \
    --arg managed_by "$MANAGED_BY" \
    --argjson schema "$STATE_SCHEMA" \
    --arg script_version "$SCRIPT_VERSION" \
    --arg service "$SERVICE_NAME" \
    --arg config "$CONFIG_FILE" \
    --arg address "$SERVER_ADDRESS" \
    --argjson port "$PORT" \
    --arg method "$METHOD" \
    --arg config_sha256 "$config_hash" \
    --arg dropin_sha256 "$dropin_hash" \
    --arg fw_requested "$FW_REQUESTED" \
    --arg fw_source "$FW_SOURCE" \
    --arg fw_result "$FW_RESULT" \
    --arg fw_comment "$FW_COMMENT" \
    --argjson fw_port "$PORT" \
    --arg source_kind "$SOURCE_KIND" \
    --arg migrated_from "$MIGRATE_FROM" \
    '{
      managed_by: $managed_by,
      schema_version: $schema,
      script_version: $script_version,
      service: $service,
      config: $config,
      server_address: $address,
      port: $port,
      method: $method,
      config_sha256: $config_sha256,
      dropin_sha256: $dropin_sha256,
      source_kind: $source_kind,
      migrated_from: (if $migrated_from == "" then null else $migrated_from end),
      firewall: {
        requested: $fw_requested,
        source: (if $fw_source == "" then null else $fw_source end),
        result: $fw_result,
        port: $fw_port,
        comment: (if $fw_comment == "" then null else $fw_comment end)
      }
    }'
}

render_outbound() {
  jq -n \
    --arg address "$SERVER_ADDRESS" \
    --argjson port "$PORT" \
    --arg method "$METHOD" \
    --rawfile password "$SECRET_FILE" \
    '{
      protocol: "shadowsocks",
      settings: {
        servers: [
          {
            address: $address,
            port: $port,
            method: $method,
            password: $password
          }
        ]
      },
      tag: "ss-relay"
    }'
}

make_ss_uri() {
  local userinfo

  userinfo=$(printf '%s' "${METHOD}:${PASSWORD}" \
    | base64 \
    | tr -d '\n=' \
    | tr '+/' '-_')
  printf 'ss://%s@%s:%s#ss-relay' "$userinfo" "$SERVER_ADDRESS" "$PORT"
}

unit_active_state() {
  systemctl is-active "$1" 2>/dev/null || true
}

unit_enabled_state() {
  systemctl is-enabled "$1" 2>/dev/null || true
}

capture_service_states() {
  DEFAULT_PREV_ACTIVE=$(unit_active_state "$SERVICE_NAME")
  DEFAULT_PREV_ENABLED=$(unit_enabled_state "$SERVICE_NAME")
  [[ -n "$DEFAULT_PREV_ACTIVE" ]] || DEFAULT_PREV_ACTIVE="inactive"
  [[ -n "$DEFAULT_PREV_ENABLED" ]] || DEFAULT_PREV_ENABLED="disabled"
  [[ -L "/etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}" ]] \
    && DEFAULT_PREV_ENABLE_PERSISTENT=1
  [[ -L "/run/systemd/system/multi-user.target.wants/${SERVICE_NAME}" ]] \
    && DEFAULT_PREV_ENABLE_RUNTIME=1

  if ((MIGRATING == 1)); then
    LEGACY_PREV_ACTIVE=$(unit_active_state "$LEGACY_SERVICE")
    LEGACY_PREV_ENABLED=$(unit_enabled_state "$LEGACY_SERVICE")
    [[ -n "$LEGACY_PREV_ACTIVE" ]] || LEGACY_PREV_ACTIVE="inactive"
    [[ -n "$LEGACY_PREV_ENABLED" ]] || LEGACY_PREV_ENABLED="disabled"
    [[ -L "/etc/systemd/system/multi-user.target.wants/${LEGACY_SERVICE}" ]] \
      && LEGACY_PREV_ENABLE_PERSISTENT=1
    [[ -L "/run/systemd/system/multi-user.target.wants/${LEGACY_SERVICE}" ]] \
      && LEGACY_PREV_ENABLE_RUNTIME=1
  fi

  return 0
}

restore_service_state() {
  local unit=$1 active=$2 enabled=$3 persistent=$4 runtime=$5 failed=0

  systemctl unmask "$unit" >/dev/null 2>&1 || failed=1
  systemctl unmask --runtime "$unit" >/dev/null 2>&1 || failed=1
  systemctl disable "$unit" >/dev/null 2>&1 || failed=1

  if ((persistent == 1)); then
    systemctl enable "$unit" >/dev/null 2>&1 || failed=1
  fi
  if ((runtime == 1)); then
    systemctl enable --runtime "$unit" >/dev/null 2>&1 || failed=1
  fi
  if ((persistent == 0 && runtime == 0)); then
    case "$enabled" in
      enabled)
        systemctl enable "$unit" >/dev/null 2>&1 || failed=1
        ;;
      enabled-runtime)
        systemctl enable --runtime "$unit" >/dev/null 2>&1 || failed=1
        ;;
    esac
  fi

  case "$active" in
    active|activating|reloading)
      systemctl start "$unit" >/dev/null 2>&1 || failed=1
      ;;
    *)
      systemctl stop "$unit" >/dev/null 2>&1 || failed=1
      systemctl reset-failed "$unit" >/dev/null 2>&1 || true
      ;;
  esac

  case "$enabled" in
    masked)
      systemctl mask "$unit" >/dev/null 2>&1 || failed=1
      ;;
    masked-runtime)
      systemctl mask --runtime "$unit" >/dev/null 2>&1 || failed=1
      ;;
    enabled|enabled-runtime|disabled|static|indirect|generated|transient|alias|not-found|"")
      ;;
    *)
      warn "无法精确解释 $unit 原启用状态：$enabled"
      ;;
  esac
  return "$failed"
}

restored_service_state_matches() {
  local unit=$1 expected_active=$2 expected_enabled=$3
  local expected_persistent=$4 expected_runtime=$5 current_active current_enabled
  local current_persistent=0 current_runtime=0 attempt

  if [[ "$expected_active" == "active" \
    || "$expected_active" == "activating" \
    || "$expected_active" == "reloading" ]]; then
    for ((attempt = 0; attempt < 8; attempt++)); do
      current_active=$(unit_active_state "$unit")
      [[ "$current_active" == "active" ]] && break
      sleep 0.25
    done
    [[ "$current_active" == "active" ]] || return 1
  else
    current_active=$(unit_active_state "$unit")
    [[ "$current_active" != "active" \
      && "$current_active" != "activating" \
      && "$current_active" != "reloading" ]] || return 1
  fi

  current_enabled=$(unit_enabled_state "$unit")
  case "$expected_enabled" in
    masked|masked-runtime|enabled|enabled-runtime)
      [[ "$current_enabled" == "$expected_enabled" ]] || return 1
      ;;
    disabled|static|indirect|generated|transient|alias|not-found|"")
      [[ "$current_enabled" != "masked" \
        && "$current_enabled" != "masked-runtime" \
        && "$current_enabled" != "enabled" \
        && "$current_enabled" != "enabled-runtime" ]] || return 1
      ;;
    *) return 1 ;;
  esac

  [[ -L "/etc/systemd/system/multi-user.target.wants/${unit}" ]] \
    && current_persistent=1
  [[ -L "/run/systemd/system/multi-user.target.wants/${unit}" ]] \
    && current_runtime=1
  [[ "$current_persistent" == "$expected_persistent" \
    && "$current_runtime" == "$expected_runtime" ]]
}

backup_path() {
  local source=$1 target_name=$2
  if [[ -e "$source" || -L "$source" ]]; then
    cp -a -- "$source" "${BACKUP_SESSION}/${target_name}"
    durable_sync "${BACKUP_SESSION}/${target_name}"
  fi
}

restore_path() {
  local target=$1 backup_name=$2 existed=$3 target_dir
  target_dir=${target%/*}
  if ((existed == 1)); then
    cp -a -- "${BACKUP_SESSION}/${backup_name}" "$target"
    durable_sync "$target"
  else
    rm -f -- "$target"
  fi
  durable_sync "$target_dir"
}

write_transaction_journal() {
  local status=$1 temp final_state_sha256=""
  local config_backup_sha256="" dropin_backup_sha256="" state_backup_sha256=""
  local legacy_config_backup_sha256="" legacy_dropin_backup_sha256=""

  [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] \
    || die "无法写入事务日志：$STATE_DIR"
  [[ ! -L "$JOURNAL_FILE" ]] \
    || die "拒绝替换事务日志符号链接：$JOURNAL_FILE"

  temp=$(mktemp "${STATE_DIR}/.transaction.XXXXXX")
  JOURNAL_TEMP=$temp
  if [[ -f "$DESIRED_STATE" ]]; then
    final_state_sha256=$(sha256_file "$DESIRED_STATE")
  fi
  [[ -f "${BACKUP_SESSION}/config.json" ]] \
    && config_backup_sha256=$(sha256_file "${BACKUP_SESSION}/config.json")
  [[ -f "${BACKUP_SESSION}/dropin.conf" ]] \
    && dropin_backup_sha256=$(sha256_file "${BACKUP_SESSION}/dropin.conf")
  [[ -f "${BACKUP_SESSION}/state.json" ]] \
    && state_backup_sha256=$(sha256_file "${BACKUP_SESSION}/state.json")
  [[ -f "${BACKUP_SESSION}/legacy-config.json" ]] \
    && legacy_config_backup_sha256=$(sha256_file "${BACKUP_SESSION}/legacy-config.json")
  [[ -f "${BACKUP_SESSION}/legacy-dropin.conf" ]] \
    && legacy_dropin_backup_sha256=$(sha256_file "${BACKUP_SESSION}/legacy-dropin.conf")
  jq -n \
    --arg managed_by "$MANAGED_BY" \
    --argjson schema "$STATE_SCHEMA" \
    --arg status "$status" \
    --arg final_state_sha256 "$final_state_sha256" \
    --arg config_backup_sha256 "$config_backup_sha256" \
    --arg dropin_backup_sha256 "$dropin_backup_sha256" \
    --arg state_backup_sha256 "$state_backup_sha256" \
    --arg legacy_config_backup_sha256 "$legacy_config_backup_sha256" \
    --arg legacy_dropin_backup_sha256 "$legacy_dropin_backup_sha256" \
    --arg backup_session "$BACKUP_SESSION" \
    --arg default_active "$DEFAULT_PREV_ACTIVE" \
    --arg default_enabled "$DEFAULT_PREV_ENABLED" \
    --argjson default_enable_persistent "$DEFAULT_PREV_ENABLE_PERSISTENT" \
    --argjson default_enable_runtime "$DEFAULT_PREV_ENABLE_RUNTIME" \
    --arg legacy_active "$LEGACY_PREV_ACTIVE" \
    --arg legacy_enabled "$LEGACY_PREV_ENABLED" \
    --argjson legacy_enable_persistent "$LEGACY_PREV_ENABLE_PERSISTENT" \
    --argjson legacy_enable_runtime "$LEGACY_PREV_ENABLE_RUNTIME" \
    --arg migrate_from "$MIGRATE_FROM" \
    --argjson migrating "$MIGRATING" \
    --argjson config_existed "$CONFIG_EXISTED" \
    --argjson dropin_existed "$DROPIN_EXISTED" \
    --argjson state_existed "$STATE_EXISTED" \
    --argjson legacy_config_existed "$LEGACY_CONFIG_EXISTED" \
    --argjson legacy_dropin_existed "$LEGACY_DROPIN_EXISTED" \
    --argjson config_dir_created "$CONFIG_DIR_CREATED" \
    --argjson dropin_dir_created "$DROPIN_DIR_CREATED" \
    --argjson state_dir_created "$STATE_DIR_CREATED" \
    --argjson ufw_mutated "$UFW_MUTATED" \
    --argjson fw_new_attempted "$FW_NEW_ATTEMPTED" \
    --argjson fw_old_delete_attempted "$FW_OLD_DELETE_ATTEMPTED" \
    --arg fw_requested "$FW_REQUESTED" \
    --arg fw_source "$FW_SOURCE" \
    --argjson fw_port "$PORT" \
    --arg fw_comment "$FW_COMMENT" \
    --arg old_fw_requested "$OLD_FW_REQUESTED" \
    --arg old_fw_source "$OLD_FW_SOURCE" \
    --arg old_fw_port "$OLD_FW_PORT" \
    --arg old_fw_comment "$OLD_FW_COMMENT" \
    '{
      managed_by: $managed_by,
      schema_version: $schema,
      status: $status,
      final_state_sha256: $final_state_sha256,
      backup_session: $backup_session,
      backup_sha256: {
        config: $config_backup_sha256,
        dropin: $dropin_backup_sha256,
        state: $state_backup_sha256,
        legacy_config: $legacy_config_backup_sha256,
        legacy_dropin: $legacy_dropin_backup_sha256
      },
      services: {
        default: {
          active: $default_active,
          enabled: $default_enabled,
          enable_persistent: $default_enable_persistent,
          enable_runtime: $default_enable_runtime
        },
        legacy: {
          active: $legacy_active,
          enabled: $legacy_enabled,
          enable_persistent: $legacy_enable_persistent,
          enable_runtime: $legacy_enable_runtime
        }
      },
      migration: {
        enabled: $migrating,
        from: (if $migrate_from == "" then null else $migrate_from end)
      },
      existed: {
        config: $config_existed,
        dropin: $dropin_existed,
        state: $state_existed,
        legacy_config: $legacy_config_existed,
        legacy_dropin: $legacy_dropin_existed
      },
      config_dir_created: $config_dir_created,
      dropin_dir_created: $dropin_dir_created,
      state_dir_created: $state_dir_created,
      firewall: {
        mutated: $ufw_mutated,
        new_attempted: $fw_new_attempted,
        old_delete_attempted: $fw_old_delete_attempted,
        desired: {
          requested: $fw_requested,
          source: (if $fw_source == "" then null else $fw_source end),
          port: $fw_port,
          comment: (if $fw_comment == "" then null else $fw_comment end)
        },
        old: {
          requested: $old_fw_requested,
          source: (if $old_fw_source == "" then null else $old_fw_source end),
          port: (if $old_fw_port == "" then null else ($old_fw_port | tonumber) end),
          comment: (if $old_fw_comment == "" then null else $old_fw_comment end)
        }
      }
    }' >"$temp"
  chmod 0600 "$temp"
  chown root:root "$temp"
  durable_sync "$temp"
  mv -f -- "$temp" "$JOURNAL_FILE"
  durable_sync "$STATE_DIR"
  JOURNAL_TEMP=""
}

require_journal_backup() {
  local existed=$1 name=$2 expected_sha256=$3
  if ((existed == 1)); then
    assert_secure_regular_file "${BACKUP_SESSION}/${name}" "事务回滚备份"
    [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ \
      && "$(sha256_file "${BACKUP_SESSION}/${name}")" == "$expected_sha256" ]] \
      || die "中断事务回滚备份校验失败：${BACKUP_SESSION}/${name}"
  else
    [[ -z "$expected_sha256" ]] \
      || die "事务日志为不存在的旧文件记录了备份校验值：$name"
  fi
}

recover_interrupted_transaction() {
  local status managed schema requested_migrate_from boolean_value expected_state_sha256
  local config_backup_sha256 dropin_backup_sha256 state_backup_sha256
  local legacy_config_backup_sha256 legacy_dropin_backup_sha256

  requested_migrate_from=$MIGRATE_FROM

  [[ -e "$JOURNAL_FILE" || -L "$JOURNAL_FILE" ]] || return 0
  assert_secure_regular_file "$JOURNAL_FILE" "事务日志"

  managed=$(jq -r '.managed_by // empty' "$JOURNAL_FILE")
  schema=$(jq -r '.schema_version // empty' "$JOURNAL_FILE")
  status=$(jq -r '.status // empty' "$JOURNAL_FILE")
  [[ "$managed" == "$MANAGED_BY" && "$schema" == "$STATE_SCHEMA" ]] \
    || die "发现无法识别的事务日志：$JOURNAL_FILE"

  if [[ "$status" == "committed" ]]; then
    expected_state_sha256=$(jq -r '.final_state_sha256 // empty' "$JOURNAL_FILE")
    [[ "$expected_state_sha256" =~ ^[0-9a-f]{64}$ ]] \
      || die "已提交事务缺少最终状态校验值，拒绝丢弃恢复凭据"
    if [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" \
      && "$(stat -c '%u' "$STATE_FILE")" == "0" \
      && $((8#$(stat -c '%a' "$STATE_FILE") & 0022)) -eq 0 ]] \
      && [[ "$(sha256_file "$STATE_FILE")" == "$expected_state_sha256" ]]; then
      rm -f -- "$JOURNAL_FILE"
      durable_sync "$STATE_DIR"
      info "已清理上次提交后遗留的事务标记"
      return 0
    fi
    die "事务标记为 committed，但最终状态文件与提交校验值不符；事务日志和备份均已保留，请先审查"
  elif [[ "$status" != "active" ]]; then
    die "事务日志状态无效：$status"
  fi

  BACKUP_SESSION=$(jq -r '.backup_session // empty' "$JOURNAL_FILE")
  [[ "$BACKUP_SESSION" =~ ^${BACKUP_ROOT}/[0-9]{8}-[0-9]{6}-[0-9]+$ ]] \
    || die "事务日志中的备份路径不安全"
  [[ -d "$BACKUP_SESSION" && ! -L "$BACKUP_SESSION" ]] \
    || die "中断事务备份目录不存在：$BACKUP_SESSION"
  assert_secure_directory "$BACKUP_SESSION"

  config_backup_sha256=$(jq -r '.backup_sha256.config // empty' "$JOURNAL_FILE")
  dropin_backup_sha256=$(jq -r '.backup_sha256.dropin // empty' "$JOURNAL_FILE")
  state_backup_sha256=$(jq -r '.backup_sha256.state // empty' "$JOURNAL_FILE")
  legacy_config_backup_sha256=$(jq -r '.backup_sha256.legacy_config // empty' "$JOURNAL_FILE")
  legacy_dropin_backup_sha256=$(jq -r '.backup_sha256.legacy_dropin // empty' "$JOURNAL_FILE")

  DEFAULT_PREV_ACTIVE=$(jq -r '.services.default.active // "inactive"' "$JOURNAL_FILE")
  DEFAULT_PREV_ENABLED=$(jq -r '.services.default.enabled // "disabled"' "$JOURNAL_FILE")
  DEFAULT_PREV_ENABLE_PERSISTENT=$(jq -r '.services.default.enable_persistent // 0' "$JOURNAL_FILE")
  DEFAULT_PREV_ENABLE_RUNTIME=$(jq -r '.services.default.enable_runtime // 0' "$JOURNAL_FILE")
  LEGACY_PREV_ACTIVE=$(jq -r '.services.legacy.active // "inactive"' "$JOURNAL_FILE")
  LEGACY_PREV_ENABLED=$(jq -r '.services.legacy.enabled // "disabled"' "$JOURNAL_FILE")
  LEGACY_PREV_ENABLE_PERSISTENT=$(jq -r '.services.legacy.enable_persistent // 0' "$JOURNAL_FILE")
  LEGACY_PREV_ENABLE_RUNTIME=$(jq -r '.services.legacy.enable_runtime // 0' "$JOURNAL_FILE")
  MIGRATING=$(jq -r '.migration.enabled // 0' "$JOURNAL_FILE")
  MIGRATE_FROM=$(jq -r '.migration.from // empty' "$JOURNAL_FILE")
  CONFIG_EXISTED=$(jq -r '.existed.config // 0' "$JOURNAL_FILE")
  DROPIN_EXISTED=$(jq -r '.existed.dropin // 0' "$JOURNAL_FILE")
  STATE_EXISTED=$(jq -r '.existed.state // 0' "$JOURNAL_FILE")
  LEGACY_CONFIG_EXISTED=$(jq -r '.existed.legacy_config // 0' "$JOURNAL_FILE")
  LEGACY_DROPIN_EXISTED=$(jq -r '.existed.legacy_dropin // 0' "$JOURNAL_FILE")
  CONFIG_DIR_CREATED=$(jq -r '.config_dir_created // 0' "$JOURNAL_FILE")
  DROPIN_DIR_CREATED=$(jq -r '.dropin_dir_created // 0' "$JOURNAL_FILE")
  STATE_DIR_CREATED=$(jq -r '.state_dir_created // 0' "$JOURNAL_FILE")
  UFW_MUTATED=$(jq -r '.firewall.mutated // 0' "$JOURNAL_FILE")
  FW_NEW_ATTEMPTED=$(jq -r '.firewall.new_attempted // 0' "$JOURNAL_FILE")
  FW_OLD_DELETE_ATTEMPTED=$(jq -r '.firewall.old_delete_attempted // 0' "$JOURNAL_FILE")
  FW_REQUESTED=$(jq -r '.firewall.desired.requested // empty' "$JOURNAL_FILE")
  FW_SOURCE=$(jq -r '.firewall.desired.source // empty' "$JOURNAL_FILE")
  PORT=$(jq -r '.firewall.desired.port // empty' "$JOURNAL_FILE")
  FW_COMMENT=$(jq -r '.firewall.desired.comment // empty' "$JOURNAL_FILE")
  OLD_FW_REQUESTED=$(jq -r '.firewall.old.requested // empty' "$JOURNAL_FILE")
  OLD_FW_SOURCE=$(jq -r '.firewall.old.source // empty' "$JOURNAL_FILE")
  OLD_FW_PORT=$(jq -r '.firewall.old.port // empty' "$JOURNAL_FILE")
  OLD_FW_COMMENT=$(jq -r '.firewall.old.comment // empty' "$JOURNAL_FILE")

  for boolean_value in \
    "$MIGRATING" "$CONFIG_EXISTED" "$DROPIN_EXISTED" "$STATE_EXISTED" \
    "$LEGACY_CONFIG_EXISTED" "$LEGACY_DROPIN_EXISTED" \
    "$CONFIG_DIR_CREATED" "$DROPIN_DIR_CREATED" "$STATE_DIR_CREATED" \
    "$UFW_MUTATED" "$FW_NEW_ATTEMPTED" "$FW_OLD_DELETE_ATTEMPTED" \
    "$DEFAULT_PREV_ENABLE_PERSISTENT" "$DEFAULT_PREV_ENABLE_RUNTIME" \
    "$LEGACY_PREV_ENABLE_PERSISTENT" "$LEGACY_PREV_ENABLE_RUNTIME"; do
    [[ "$boolean_value" =~ ^[01]$ ]] \
      || die "事务日志包含无效布尔值"
  done

  if ((FW_NEW_ATTEMPTED == 1)); then
    validate_port "$PORT" || die "事务日志中的新 UFW 端口无效"
    [[ "$FW_REQUESTED" == "all" || "$FW_REQUESTED" == "restricted" ]] \
      || die "事务日志中的新 UFW 模式无效"
    [[ "$FW_COMMENT" =~ ^${FIREWALL_PREFIX}-[0-9]{4,5}-[0-9a-f]{6}$ ]] \
      || die "事务日志中的新 UFW 标记无效"
    if [[ "$FW_REQUESTED" == "restricted" ]]; then
      is_ipv4_cidr "$FW_SOURCE" || die "事务日志中的新 UFW 来源无效"
    fi
  fi
  if ((FW_OLD_DELETE_ATTEMPTED == 1)); then
    validate_port "$OLD_FW_PORT" || die "事务日志中的旧 UFW 端口无效"
    [[ "$OLD_FW_REQUESTED" == "all" || "$OLD_FW_REQUESTED" == "restricted" ]] \
      || die "事务日志中的旧 UFW 模式无效"
    [[ "$OLD_FW_COMMENT" =~ ^${FIREWALL_PREFIX}-[0-9]{4,5}-[0-9a-f]{6}$ ]] \
      || die "事务日志中的旧 UFW 标记无效"
    if [[ "$OLD_FW_REQUESTED" == "restricted" ]]; then
      is_ipv4_cidr "$OLD_FW_SOURCE" || die "事务日志中的旧 UFW 来源无效"
    fi
  fi

  if ((MIGRATING == 1)); then
    validate_instance_name "$MIGRATE_FROM" \
      || die "事务日志中的迁移实例名无效"
    LEGACY_CONFIG="${CONFIG_DIR}/${MIGRATE_FROM}.json"
    LEGACY_SERVICE="shadowsocks-libev-server@${MIGRATE_FROM}.service"
    LEGACY_DROPIN="/etc/systemd/system/${LEGACY_SERVICE}.d/10-ss-config-access.conf"
  fi

  require_journal_backup "$CONFIG_EXISTED" config.json "$config_backup_sha256"
  require_journal_backup "$DROPIN_EXISTED" dropin.conf "$dropin_backup_sha256"
  require_journal_backup "$STATE_EXISTED" state.json "$state_backup_sha256"
  if ((MIGRATING == 1)); then
    require_journal_backup \
      "$LEGACY_CONFIG_EXISTED" legacy-config.json "$legacy_config_backup_sha256"
    require_journal_backup \
      "$LEGACY_DROPIN_EXISTED" legacy-dropin.conf "$legacy_dropin_backup_sha256"
  fi

  warn "检测到上次被断电或 SIGKILL 中断的事务，正在自动回滚"
  SNAPSHOT_READY=1
  TARGET_FILES_MUTATED=1
  LEGACY_FILES_MUTATED=$MIGRATING
  TX_ACTIVE=1
  rollback
  reset_transaction_runtime
  MIGRATE_FROM=$requested_migrate_from
  info "中断事务已恢复，可继续本次部署"
}

reset_transaction_runtime() {
  TX_ACTIVE=0
  SNAPSHOT_READY=0
  TARGET_FILES_MUTATED=0
  LEGACY_FILES_MUTATED=0
  BACKUP_SESSION=""
  CONFIG_EXISTED=0
  DROPIN_EXISTED=0
  STATE_EXISTED=0
  LEGACY_CONFIG_EXISTED=0
  LEGACY_DROPIN_EXISTED=0
  CONFIG_DIR_CREATED=0
  DROPIN_DIR_CREATED=0
  STATE_DIR_CREATED=0
  CONFIG_GROUP_CREATED=0
  DEFAULT_PREV_ACTIVE="inactive"
  DEFAULT_PREV_ENABLED="disabled"
  DEFAULT_PREV_ENABLE_PERSISTENT=0
  DEFAULT_PREV_ENABLE_RUNTIME=0
  LEGACY_PREV_ACTIVE="inactive"
  LEGACY_PREV_ENABLED="disabled"
  LEGACY_PREV_ENABLE_PERSISTENT=0
  LEGACY_PREV_ENABLE_RUNTIME=0
  MIGRATING=0
  LEGACY_CONFIG=""
  LEGACY_SERVICE=""
  LEGACY_DROPIN=""
  OLD_FW_REQUESTED=""
  OLD_FW_SOURCE=""
  OLD_FW_PORT=""
  OLD_FW_COMMENT=""
  FW_REQUESTED="all"
  FW_SOURCE=""
  FW_RESULT=""
  FW_COMMENT=""
  FW_NEEDS_CHANGE=0
  FW_OLD_RULE_COUNT=0
  FW_NEW_RULE_COUNT=0
  UFW_AVAILABLE=0
  UFW_ACTIVE=0
  UFW_MUTATED=0
  FW_NEW_ATTEMPTED=0
  FW_OLD_DELETE_ATTEMPTED=0
  SOURCE_KIND="fresh"
  EXISTING_CONFIG=0
  MANAGED_STATE=0
  CONFIG_CHANGE=0
  DROPIN_CHANGE=0
  STATE_CHANGE=0
  SERVICE_NEEDS_START=0
  SERVICE_NEEDS_ENABLE=0
  CONFIG_RELOAD_REQUIRED=0
  PORT=""
  PASSWORD=""
  METHOD=""
}

begin_transaction() {
  local stamp

  capture_service_states

  [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]] && CONFIG_EXISTED=1
  [[ -e "$DROPIN_FILE" || -L "$DROPIN_FILE" ]] && DROPIN_EXISTED=1
  [[ -e "$STATE_FILE" || -L "$STATE_FILE" ]] && STATE_EXISTED=1
  if ((MIGRATING == 1)); then
    [[ -e "$LEGACY_CONFIG" || -L "$LEGACY_CONFIG" ]] \
      && LEGACY_CONFIG_EXISTED=1
    [[ -e "$LEGACY_DROPIN" || -L "$LEGACY_DROPIN" ]] \
      && LEGACY_DROPIN_EXISTED=1
  fi
  TX_ACTIVE=1
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  if [[ -e "$BACKUP_ROOT" || -L "$BACKUP_ROOT" ]]; then
    assert_secure_directory "$BACKUP_ROOT"
  else
    install -d -o root -g root -m 0700 "$BACKUP_ROOT"
    durable_sync "/var/backups"
  fi
  BACKUP_SESSION="${BACKUP_ROOT}/${stamp}"
  install -d -m 0700 "$BACKUP_SESSION"
  durable_sync "$BACKUP_ROOT"

  backup_path "$CONFIG_FILE" config.json
  backup_path "$DROPIN_FILE" dropin.conf
  backup_path "$STATE_FILE" state.json
  if ((MIGRATING == 1)); then
    backup_path "$LEGACY_CONFIG" legacy-config.json
    backup_path "$LEGACY_DROPIN" legacy-dropin.conf
  fi
  durable_sync "$BACKUP_SESSION"
  SNAPSHOT_READY=1

  if [[ ! -e "$STATE_DIR" ]]; then
    install -d -o root -g root -m 0700 "$STATE_DIR"
    durable_sync "/var/lib"
    STATE_DIR_CREATED=1
  else
    assert_secure_directory "$STATE_DIR"
  fi
  write_transaction_journal active
}

snapshot_path_restored() {
  local target=$1 backup_name=$2 existed=$3

  if ((existed == 1)); then
    [[ -e "$target" || -L "$target" ]] \
      && cmp -s "${BACKUP_SESSION}/${backup_name}" "$target" \
      && [[ "$(stat -c '%u:%g:%a' "${BACKUP_SESSION}/${backup_name}")" \
        == "$(stat -c '%u:%g:%a' "$target")" ]]
  else
    [[ ! -e "$target" && ! -L "$target" ]]
  fi
}

rollback() {
  local rollback_failed=0

  warn "部署未完成，正在恢复事务开始前的状态"
  TX_ACTIVE=0

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || rollback_failed=1

  if ((SNAPSHOT_READY == 1)); then
    if ((TARGET_FILES_MUTATED == 1)); then
      restore_path "$CONFIG_FILE" config.json "$CONFIG_EXISTED" \
        || rollback_failed=1
      restore_path "$DROPIN_FILE" dropin.conf "$DROPIN_EXISTED" \
        || rollback_failed=1
      restore_path "$STATE_FILE" state.json "$STATE_EXISTED" \
        || rollback_failed=1
      snapshot_path_restored "$CONFIG_FILE" config.json "$CONFIG_EXISTED" \
        || rollback_failed=1
      snapshot_path_restored "$DROPIN_FILE" dropin.conf "$DROPIN_EXISTED" \
        || rollback_failed=1
      snapshot_path_restored "$STATE_FILE" state.json "$STATE_EXISTED" \
        || rollback_failed=1
    fi

    if ((LEGACY_FILES_MUTATED == 1)); then
      restore_path "$LEGACY_CONFIG" legacy-config.json "$LEGACY_CONFIG_EXISTED" \
        || rollback_failed=1
      restore_path "$LEGACY_DROPIN" legacy-dropin.conf "$LEGACY_DROPIN_EXISTED" \
        || rollback_failed=1
      snapshot_path_restored \
        "$LEGACY_CONFIG" legacy-config.json "$LEGACY_CONFIG_EXISTED" \
        || rollback_failed=1
      snapshot_path_restored \
        "$LEGACY_DROPIN" legacy-dropin.conf "$LEGACY_DROPIN_EXISTED" \
        || rollback_failed=1
    fi

    if ((UFW_MUTATED == 1)); then
      if ((FW_NEW_ATTEMPTED == 1)); then
        remove_all_managed_ufw_rules \
          "$FW_REQUESTED" "$FW_SOURCE" "$PORT" "$FW_COMMENT" \
          >/dev/null 2>&1 || rollback_failed=1
      fi
      if ((FW_OLD_DELETE_ATTEMPTED == 1)); then
        ensure_managed_ufw_rule_pair \
          "$OLD_FW_REQUESTED" "$OLD_FW_SOURCE" "$OLD_FW_PORT" "$OLD_FW_COMMENT" \
          >/dev/null 2>&1 || rollback_failed=1
      fi
    fi
  fi

  systemctl daemon-reload >/dev/null 2>&1 || rollback_failed=1
  restore_service_state \
    "$SERVICE_NAME" "$DEFAULT_PREV_ACTIVE" "$DEFAULT_PREV_ENABLED" \
    "$DEFAULT_PREV_ENABLE_PERSISTENT" "$DEFAULT_PREV_ENABLE_RUNTIME" \
    || rollback_failed=1
  restored_service_state_matches \
    "$SERVICE_NAME" "$DEFAULT_PREV_ACTIVE" "$DEFAULT_PREV_ENABLED" \
    "$DEFAULT_PREV_ENABLE_PERSISTENT" "$DEFAULT_PREV_ENABLE_RUNTIME" \
    || rollback_failed=1

  if ((MIGRATING == 1)); then
    restore_service_state \
      "$LEGACY_SERVICE" "$LEGACY_PREV_ACTIVE" "$LEGACY_PREV_ENABLED" \
      "$LEGACY_PREV_ENABLE_PERSISTENT" "$LEGACY_PREV_ENABLE_RUNTIME" \
      || rollback_failed=1
    restored_service_state_matches \
      "$LEGACY_SERVICE" "$LEGACY_PREV_ACTIVE" "$LEGACY_PREV_ENABLED" \
      "$LEGACY_PREV_ENABLE_PERSISTENT" "$LEGACY_PREV_ENABLE_RUNTIME" \
      || rollback_failed=1
  fi

  sync || rollback_failed=1
  if ((rollback_failed == 0)); then
    if rm -f -- "$JOURNAL_FILE"; then
      durable_sync "$STATE_DIR" || rollback_failed=1
    else
      rollback_failed=1
    fi
  fi
  if ((rollback_failed == 0)); then
    if ((CONFIG_DIR_CREATED == 1)); then
      rmdir "$CONFIG_DIR" >/dev/null 2>&1 || true
    fi
    if ((DROPIN_DIR_CREATED == 1)); then
      rmdir "$DROPIN_DIR" >/dev/null 2>&1 || true
    fi
    if ((STATE_DIR_CREATED == 1)); then
      rmdir "$STATE_DIR" >/dev/null 2>&1 || true
    fi
  fi
  if ((CONFIG_GROUP_CREATED == 1)); then
    warn "本次创建的空系统组 $CONFIG_GROUP 为避免误删账号/文件而保留，可在确认未使用后手动删除"
  fi

  if ((rollback_failed == 1)); then
    warn "回滚未能完整验证；事务日志已保留：$JOURNAL_FILE"
    warn "请勿继续覆盖，修复系统状态后重新运行本脚本以重试恢复"
    return 1
  fi

  warn "原配置和服务状态已恢复；APT 已安装的软件包不会自动卸载"
  return 0
}

ensure_target_directories() {
  if [[ ! -e "$CONFIG_DIR" ]]; then
    install -d -m 0755 "$CONFIG_DIR"
    CONFIG_DIR_CREATED=1
  else
    [[ -d "$CONFIG_DIR" && ! -L "$CONFIG_DIR" ]] \
      || die "配置目录不是安全的普通目录：$CONFIG_DIR"
  fi

  if [[ ! -e "$DROPIN_DIR" ]]; then
    install -d -m 0755 "$DROPIN_DIR"
    DROPIN_DIR_CREATED=1
  else
    [[ -d "$DROPIN_DIR" && ! -L "$DROPIN_DIR" ]] \
      || die "drop-in 目录不是安全的普通目录：$DROPIN_DIR"
  fi

  if [[ ! -e "$STATE_DIR" ]]; then
    install -d -m 0700 "$STATE_DIR"
    STATE_DIR_CREATED=1
  else
    [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] \
      || die "状态目录不是安全的普通目录：$STATE_DIR"
  fi
}

atomic_install() {
  local source=$1 target=$2 mode=$3 owner=$4 group=$5 target_dir temp

  target_dir=${target%/*}
  temp=$(mktemp "${target_dir}/.ss-libev-relay.XXXXXX")
  ATOMIC_TEMP=$temp
  install -o "$owner" -g "$group" -m "$mode" "$source" "$temp"
  durable_sync "$temp"
  TARGET_FILES_MUTATED=1
  mv -f -- "$temp" "$target"
  durable_sync "$target_dir"
  ATOMIC_TEMP=""
}

ufw_is_active() {
  LC_ALL=C ufw status 2>/dev/null | head -n 1 | grep -Fxq "Status: active"
}

ufw_show_added() {
  local added
  if ! added=$(LC_ALL=C ufw show added 2>/dev/null); then
    return 1
  fi
  printf '%s\n' "$added"
}

ufw_rule_count() {
  local comment=$1 added
  [[ -n "$comment" ]] || {
    printf '0\n'
    return
  }
  if ! added=$(ufw_show_added); then
    return 1
  fi
  awk -v needle="comment '${comment}'" '
      index($0, needle) {count++}
      END {print count + 0}
    ' <<<"$added"
}

ufw_rules_match() {
  local requested=$1 source=$2 port=$3 comment=$4
  local tcp_rule udp_rule added

  if ! added=$(ufw_show_added); then
    return 1
  fi
  if [[ "$requested" == "restricted" ]]; then
    tcp_rule="ufw allow from ${source} to any port ${port} proto tcp comment '${comment}'"
    udp_rule="ufw allow from ${source} to any port ${port} proto udp comment '${comment}'"
  else
    tcp_rule="ufw allow ${port}/tcp comment '${comment}'"
    udp_rule="ufw allow ${port}/udp comment '${comment}'"
  fi

  grep -Fxq "$tcp_rule" <<<"$added" \
    && grep -Fxq "$udp_rule" <<<"$added"
}

ufw_rules_are_expected_subset() {
  local requested=$1 source=$2 port=$3 comment=$4
  local tcp_rule udp_rule line added

  if [[ "$requested" == "restricted" ]]; then
    tcp_rule="ufw allow from ${source} to any port ${port} proto tcp comment '${comment}'"
    udp_rule="ufw allow from ${source} to any port ${port} proto udp comment '${comment}'"
  else
    tcp_rule="ufw allow ${port}/tcp comment '${comment}'"
    udp_rule="ufw allow ${port}/udp comment '${comment}'"
  fi

  if ! added=$(ufw_show_added); then
    return 1
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" == *"comment '${comment}'"* ]] || continue
    [[ "$line" == "$tcp_rule" || "$line" == "$udp_rule" ]] || return 1
  done <<<"$added"
}

ufw_default_input_is_restrictive() {
  local policy
  [[ -r /etc/default/ufw ]] || return 1
  policy=$(awk -F= '
    $1 == "DEFAULT_INPUT_POLICY" {
      gsub(/["[:space:]]/, "", $2)
      print toupper($2)
      exit
    }
  ' /etc/default/ufw)
  [[ "$policy" == "DROP" || "$policy" == "REJECT" ]]
}

ufw_has_conflicting_port_rule() {
  local line added
  if ! added=$(ufw_show_added); then
    return 2
  fi
  while IFS= read -r line; do
    [[ "$line" == ufw\ allow* ]] || continue
    if [[ -n "$OLD_FW_COMMENT" && "$line" == *"comment '${OLD_FW_COMMENT}'"* ]]; then
      continue
    fi
    if printf '%s\n' "$line" \
      | grep -Eq "(^|[[:space:]])${PORT}(/(tcp|udp))?([[:space:]]|$)|port[[:space:]]+${PORT}([[:space:]]|$)"; then
      return 0
    fi
  done <<<"$added"
  return 1
}

new_firewall_comment() {
  printf '%s-%s-%s\n' \
    "$FIREWALL_PREFIX" "$PORT" "$(openssl rand -hex 3)"
}

inspect_firewall() {
  local same_policy=0 orphan_count=0 added conflict_status

  if command -v ufw >/dev/null 2>&1; then
    UFW_AVAILABLE=1
    if ufw_is_active; then
      UFW_ACTIVE=1
    fi
  fi

  if ((UFW_AVAILABLE == 0)); then
    if [[ "$FW_REQUESTED" == "restricted" ]]; then
      die "--allow-from 需要已安装并启用 UFW；本脚本不会静默假装已限制来源"
    fi
    [[ -z "$OLD_FW_COMMENT" ]] \
      || die "状态记录了旧 UFW 规则，但当前找不到 UFW，无法安全管理其生命周期"
    if [[ "$FW_REQUESTED" == "disabled" ]]; then
      FW_RESULT="disabled"
    else
      FW_RESULT="ufw-missing"
    fi
    FW_COMMENT=""
    FW_NEEDS_CHANGE=0
    return
  fi

  if ! added=$(ufw_show_added); then
    die "无法读取 UFW 用户规则，拒绝在未知状态下继续"
  fi

  if [[ -n "$OLD_FW_COMMENT" ]]; then
    FW_OLD_RULE_COUNT=$(ufw_rule_count "$OLD_FW_COMMENT")
    if ((FW_OLD_RULE_COUNT != 0)); then
      if ((FW_OLD_RULE_COUNT != 2)) \
        || ! ufw_rules_match \
          "$OLD_FW_REQUESTED" "$OLD_FW_SOURCE" "$OLD_FW_PORT" "$OLD_FW_COMMENT"; then
        die "状态认领的旧 UFW 规则语义已漂移，拒绝按注释误删"
      fi
    fi
  fi

  if [[ "$FW_REQUESTED" == "restricted" ]]; then
    ((UFW_ACTIVE == 1)) \
      || die "--allow-from 需要 UFW 已启用，否则不能保证来源限制"
    ufw_default_input_is_restrictive \
      || die "UFW 默认入站策略不是 DROP/REJECT，不能保证仅允许指定来源"
  fi

  if [[ "$FW_REQUESTED" != "disabled" ]]; then
    conflict_status=0
    ufw_has_conflicting_port_rule || conflict_status=$?
    case "$conflict_status" in
      0)
        die "UFW 中存在该端口的非本脚本 allow 规则；请先审查，或使用 --no-firewall"
        ;;
      1) ;;
      *) die "无法审计 UFW 用户规则，拒绝继续" ;;
    esac
  fi

  if [[ "$FW_REQUESTED" == "$OLD_FW_REQUESTED" \
    && "$FW_SOURCE" == "$OLD_FW_SOURCE" \
    && "$PORT" == "$OLD_FW_PORT" \
    && -n "$OLD_FW_COMMENT" ]]; then
    same_policy=1
  fi

  if [[ "$FW_REQUESTED" == "disabled" ]]; then
    FW_RESULT="disabled"
    FW_COMMENT=""
    ((FW_OLD_RULE_COUNT == 0)) || FW_NEEDS_CHANGE=1
  else
    if [[ "$FW_REQUESTED" == "restricted" ]]; then
      if ((UFW_ACTIVE == 1)); then
        FW_RESULT="active（来源 ${FW_SOURCE}）"
      else
        FW_RESULT="prepared-ufw-inactive（来源 ${FW_SOURCE}）"
      fi
    elif ((UFW_ACTIVE == 1)); then
      FW_RESULT="active"
    else
      FW_RESULT="prepared-ufw-inactive"
    fi
    if ((same_policy == 1)); then
      FW_COMMENT=$OLD_FW_COMMENT
      ((FW_OLD_RULE_COUNT == 2)) || FW_NEEDS_CHANGE=1
    else
      FW_COMMENT=$(new_firewall_comment)
      FW_NEEDS_CHANGE=1
    fi
  fi

  if ((MANAGED_STATE == 0)); then
    orphan_count=$(grep -F -c "comment '${FIREWALL_PREFIX}-" <<<"$added" || true)
    if ((orphan_count > 0)); then
      warn "发现无状态文件认领的 v1.2 UFW 规则；脚本不会自动删除，请人工审查"
    fi
  fi
}

add_ufw_rules_for() {
  local requested=$1 source=$2 port=$3 comment=$4
  if [[ "$requested" != "restricted" ]]; then
    source="0.0.0.0/0"
  fi

  ufw allow in proto tcp from "$source" to 0.0.0.0/0 \
    port "$port" comment "$comment" >/dev/null
  ufw allow in proto udp from "$source" to 0.0.0.0/0 \
    port "$port" comment "$comment" >/dev/null
}

delete_ufw_rules_for() {
  local requested=$1 source=$2 port=$3 comment=$4

  [[ -n "$comment" ]] || return 0
  if [[ "$requested" == "restricted" ]]; then
    [[ -n "$source" ]] || return 1
  else
    source="0.0.0.0/0"
  fi

  ufw --force delete allow in proto tcp from "$source" to 0.0.0.0/0 \
    port "$port" comment "$comment" >/dev/null 2>&1 || true
  ufw --force delete allow in proto udp from "$source" to 0.0.0.0/0 \
    port "$port" comment "$comment" >/dev/null 2>&1 || true
}

remove_all_managed_ufw_rules() {
  local requested=$1 source=$2 port=$3 comment=$4 attempt before after

  [[ -n "$comment" ]] || return 0
  ufw_rules_are_expected_subset "$requested" "$source" "$port" "$comment" \
    || return 1

  for ((attempt = 0; attempt < 16; attempt++)); do
    if ! before=$(ufw_rule_count "$comment"); then
      return 1
    fi
    ((before > 0)) || return 0
    delete_ufw_rules_for "$requested" "$source" "$port" "$comment"
    if ! after=$(ufw_rule_count "$comment"); then
      return 1
    fi
    ((after < before)) || return 1
  done
  if ! after=$(ufw_rule_count "$comment"); then
    return 1
  fi
  [[ "$after" == "0" ]]
}

ensure_managed_ufw_rule_pair() {
  local requested=$1 source=$2 port=$3 comment=$4 count

  if ! count=$(ufw_rule_count "$comment"); then
    return 1
  fi
  if ((count == 2)) \
    && ufw_rules_match "$requested" "$source" "$port" "$comment"; then
    return 0
  fi

  remove_all_managed_ufw_rules "$requested" "$source" "$port" "$comment" \
    || return 1
  add_ufw_rules_for "$requested" "$source" "$port" "$comment" \
    || return 1
  if ! count=$(ufw_rule_count "$comment"); then
    return 1
  fi
  [[ "$count" == "2" ]] \
    && ufw_rules_match "$requested" "$source" "$port" "$comment"
}

reconcile_firewall() {
  ((FW_NEEDS_CHANGE == 1)) || return 0
  ((UFW_AVAILABLE == 1)) || return 0

  UFW_MUTATED=1
  if [[ "$FW_REQUESTED" != "disabled" ]]; then
    FW_NEW_ATTEMPTED=1
    write_transaction_journal active
    add_ufw_rules_for "$FW_REQUESTED" "$FW_SOURCE" "$PORT" "$FW_COMMENT"
    FW_NEW_RULE_COUNT=$(ufw_rule_count "$FW_COMMENT")
    if ((FW_NEW_RULE_COUNT != 2)) \
      || ! ufw_rules_match "$FW_REQUESTED" "$FW_SOURCE" "$PORT" "$FW_COMMENT"; then
      die "UFW TCP/UDP 规则验证失败，已进入回滚"
    fi
  fi

  if ((FW_OLD_RULE_COUNT > 0)) \
    && [[ "$OLD_FW_COMMENT" != "$FW_COMMENT" ]]; then
    FW_OLD_DELETE_ATTEMPTED=1
    write_transaction_journal active
    remove_all_managed_ufw_rules \
      "$OLD_FW_REQUESTED" "$OLD_FW_SOURCE" "$OLD_FW_PORT" "$OLD_FW_COMMENT"
    [[ "$(ufw_rule_count "$OLD_FW_COMMENT")" == "0" ]] \
      || die "旧 UFW 规则未能完整删除，已进入回滚"
  fi
}

service_socket_owned() {
  local protocol=$1 port=$2 pid=$3 flag output
  case "$protocol" in
    tcp) flag=-lntp ;;
    udp) flag=-lnup ;;
    *) return 1 ;;
  esac
  output=$(ss -H -4 "$flag" "sport = :${port}" 2>/dev/null || true)
  [[ -n "$output" && "$output" == *"pid=${pid},"* ]]
}

service_identity_secure() {
  local pid=$1 config_gid uid_line gid_line groups_line effective_uid effective_gid group

  [[ -r "/proc/${pid}/status" ]] || return 1
  config_gid=$(getent group "$CONFIG_GROUP" | awk -F: '{print $3}')
  [[ "$config_gid" =~ ^[0-9]+$ ]] || return 1

  uid_line=$(awk '$1 == "Uid:" {print; exit}' "/proc/${pid}/status")
  gid_line=$(awk '$1 == "Gid:" {print; exit}' "/proc/${pid}/status")
  groups_line=$(awk '$1 == "Groups:" {for (i=2; i<=NF; i++) print $i}' "/proc/${pid}/status")
  effective_uid=$(awk '{print $3}' <<<"$uid_line")
  effective_gid=$(awk '{print $3}' <<<"$gid_line")
  [[ "$effective_uid" =~ ^[0-9]+$ && "$effective_uid" != "0" ]] || return 1
  [[ "$effective_gid" =~ ^[0-9]+$ && "$effective_gid" != "0" ]] || return 1

  while IFS= read -r group; do
    [[ "$group" == "$config_gid" ]] && return 0
  done <<<"$groups_line"
  return 1
}

service_healthy() {
  local pid
  systemctl is-active --quiet "$SERVICE_NAME" || return 1
  pid=$(systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null || true)
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  service_identity_secure "$pid" \
    && service_socket_owned tcp "$PORT" "$pid" \
    && service_socket_owned udp "$PORT" "$pid"
}

wait_for_service() {
  local attempt
  for ((attempt = 0; attempt < 24; attempt++)); do
    if service_healthy; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

show_port_owner() {
  ss -H -lntp "sport = :${PORT}" 2>/dev/null >&2 || true
  ss -H -lnup "sport = :${PORT}" 2>/dev/null >&2 || true
}

prepare_desired_files() {
  local dropin_hash config_hash enabled_state

  write_secret_file
  render_config >"$DESIRED_CONFIG"
  jq -e '
    .server == "0.0.0.0" and
    (.server_port | type == "number") and
    (.password | type == "string") and
    .mode == "tcp_and_udp"
  ' "$DESIRED_CONFIG" >/dev/null \
    || die "生成的 Shadowsocks JSON 校验失败"
  chmod 0600 "$DESIRED_CONFIG"
  config_hash=$(sha256_file "$DESIRED_CONFIG")

  render_dropin >"$DESIRED_DROPIN"
  chmod 0644 "$DESIRED_DROPIN"
  dropin_hash=$(sha256_file "$DESIRED_DROPIN")

  [[ -f "$CONFIG_FILE" ]] && cmp -s "$DESIRED_CONFIG" "$CONFIG_FILE" \
    || CONFIG_CHANGE=1
  [[ -f "$DROPIN_FILE" ]] && cmp -s "$DESIRED_DROPIN" "$DROPIN_FILE" \
    || DROPIN_CHANGE=1
  if [[ -f "$CONFIG_FILE" \
    && "$(stat -c '%u:%G:%a' "$CONFIG_FILE")" != "0:${CONFIG_GROUP}:640" ]]; then
    CONFIG_CHANGE=1
  fi
  if [[ -f "$DROPIN_FILE" \
    && "$(stat -c '%u:%g:%a' "$DROPIN_FILE")" != "0:0:644" ]]; then
    DROPIN_CHANGE=1
  fi

  inspect_firewall
  render_state "$dropin_hash" "$config_hash" >"$DESIRED_STATE"
  chmod 0600 "$DESIRED_STATE"
  [[ -f "$STATE_FILE" ]] && cmp -s "$DESIRED_STATE" "$STATE_FILE" \
    || STATE_CHANGE=1
  if [[ -f "$STATE_FILE" \
    && "$(stat -c '%u:%g:%a' "$STATE_FILE")" != "0:0:600" ]]; then
    STATE_CHANGE=1
  fi

  enabled_state=$(unit_enabled_state "$SERVICE_NAME")
  [[ "$enabled_state" == "enabled" ]] || SERVICE_NEEDS_ENABLE=1
  ((CONFIG_RELOAD_REQUIRED == 0)) || SERVICE_NEEDS_START=1
  service_healthy || SERVICE_NEEDS_START=1
}

apply_target_files() {
  ensure_target_directories
  write_transaction_journal active

  if ((CONFIG_CHANGE == 1)); then
    [[ ! -L "$CONFIG_FILE" ]] || die "拒绝替换符号链接：$CONFIG_FILE"
    atomic_install "$DESIRED_CONFIG" "$CONFIG_FILE" 0640 root "$CONFIG_GROUP"
  fi

  if ((DROPIN_CHANGE == 1)); then
    [[ ! -L "$DROPIN_FILE" ]] || die "拒绝替换符号链接：$DROPIN_FILE"
    atomic_install "$DESIRED_DROPIN" "$DROPIN_FILE" 0644 root root
  fi
}

start_and_verify_service() {
  local must_stop=0

  ensure_config_group

  if ((CONFIG_CHANGE == 1 || DROPIN_CHANGE == 1 || SERVICE_NEEDS_START == 1)); then
    must_stop=1
  fi

  if ((must_stop == 1)); then
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    if ((MIGRATING == 1)); then
      systemctl stop "$LEGACY_SERVICE"
    fi

    if port_in_use "$PORT"; then
      show_port_owner
      die "端口 $PORT 已被其他进程占用"
    fi
  fi

  apply_target_files
  systemctl unmask "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl unmask --runtime "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl daemon-reload
  verify_effective_unit
  systemctl enable "$SERVICE_NAME" >/dev/null

  if ((must_stop == 1)); then
    info "启动并验证 $SERVICE_NAME"
    if ! systemctl start "$SERVICE_NAME"; then
      journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
      die "服务启动失败"
    fi
  fi

  if ! wait_for_service; then
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
    die "服务未保持 active，或 TCP/UDP 监听不属于该服务 MainPID"
  fi

  if ((MIGRATING == 1)); then
    systemctl disable "$LEGACY_SERVICE" >/dev/null
    LEGACY_FILES_MUTATED=1
    chown root:root "$LEGACY_CONFIG"
    chmod 0600 "$LEGACY_CONFIG"
    rm -f -- "$LEGACY_DROPIN"
    systemctl daemon-reload
  fi
}

write_state() {
  ensure_target_directories
  atomic_install "$DESIRED_STATE" "$STATE_FILE" 0600 root root
}

commit_transaction() {
  sync
  write_transaction_journal committed
  TX_ACTIVE=0
  if ! rm -f -- "$JOURNAL_FILE"; then
    warn "部署已提交，但事务标记暂未删除；下次运行会自动核对并清理：$JOURNAL_FILE"
  else
    durable_sync "$STATE_DIR"
  fi
}

prune_backups() {
  local -a old_backups=()
  local item

  while IFS= read -r item; do
    old_backups+=("$item")
  done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn \
    | awk 'NR > 5 {sub(/^[^ ]+ /, ""); print}')

  for item in "${old_backups[@]}"; do
    case "$item" in
      "$BACKUP_ROOT"/*) rm -rf -- "$item" ;;
      *) warn "拒绝清理非预期备份目录：$item" ;;
    esac
  done
}

print_summary() {
  local outcome=$1 uri
  uri=$(make_ss_uri)

  printf '\n============================================================\n'
  printf ' Shadowsocks-libev v%s — %s\n' "$SCRIPT_VERSION" "$outcome"
  printf '============================================================\n'
  printf '服务器地址：%s\n' "$SERVER_ADDRESS"
  printf '端口：      %s\n' "$PORT"
  printf '用户名：    无\n'
  printf '密码：      %s\n' "$PASSWORD"
  printf '加密方式：  %s\n' "$METHOD"
  printf '网络：      TCP + UDP\n'
  printf '服务：      %s\n' "$SERVICE_NAME"
  printf '配置：      %s（root:%s 0640）\n' "$CONFIG_FILE" "$CONFIG_GROUP"
  printf '防火墙：    %s\n' "$FW_RESULT"
  printf 'SS 链接：   %s\n' "$uri"
  printf '\n3x-ui 填写提示：\n'
  printf '  发送通过：留空\n'
  printf '  地址/端口/密码/加密：使用上方值\n'
  printf '  UDP over TCP：关闭；传输：RAW；安全：无；Mux：关闭\n'
  printf '\n3x-ui Outbound JSON：\n'
  render_outbound
  printf '============================================================\n'
}

dry_run() {
  if ((PORT_WAS_SET == 1)); then
    PORT=$REQUESTED_PORT
  else
    PORT=$((16#$(openssl rand -hex 2) % 40001 + 20000))
  fi
  if ((METHOD_WAS_SET == 1)); then
    METHOD=$REQUESTED_METHOD
  else
    METHOD=$DEFAULT_METHOD
  fi
  if [[ -n "$PASSWORD_FILE" ]]; then
    read_password_file
  else
    PASSWORD=$(random_password)
  fi
  validate_password

  if ((SERVER_WAS_SET == 0)); then
    SERVER_ADDRESS=$(detect_server_address || true)
    [[ -n "$SERVER_ADDRESS" ]] \
      || die "dry-run 无法自动识别公网 IPv4，请使用 --server"
  fi

  if ((NO_FIREWALL == 1)); then
    FW_RESULT="disabled（预览）"
  elif ((ALLOW_FROM_WAS_SET == 1)); then
    FW_RESULT="restricted:${ALLOW_FROM}（预览）"
  else
    FW_RESULT="all IPv4（预览）"
  fi

  write_secret_file
  printf '\n将写入的服务端配置：\n'
  render_config
  print_summary "预览，未部署"
}

acquire_lock() {
  command -v flock >/dev/null 2>&1 \
    || die "系统缺少 flock（util-linux），无法安全防止并发部署"

  if [[ ! -e "$LOCK_DIR" ]]; then
    install -d -o root -g root -m 0700 "$LOCK_DIR"
  else
    assert_secure_directory "$LOCK_DIR"
    [[ "$(stat -c '%a' "$LOCK_DIR")" == "700" ]] \
      || die "锁目录权限必须是 0700：$LOCK_DIR"
  fi
  [[ ! -L "$LOCK_FILE" ]] || die "拒绝跟随锁文件符号链接：$LOCK_FILE"
  [[ ! -e "$LOCK_FILE" || -f "$LOCK_FILE" ]] \
    || die "锁路径不是普通文件：$LOCK_FILE"

  exec 9>"$LOCK_FILE"
  chown root:root "$LOCK_FILE"
  chmod 0600 "$LOCK_FILE"
  flock -n 9 || die "另一个 ss-libev-relay 部署正在运行"
}

deploy() {
  local any_change=0

  preflight_existing_directories
  validate_existing_config_group
  validate_unit_layout
  recover_interrupted_transaction
  preflight_existing_directories
  validate_existing_config_group
  validate_unit_layout
  discover_source
  resolve_inputs
  prepare_desired_files

  if ((CONFIG_CHANGE == 1 || DROPIN_CHANGE == 1 || STATE_CHANGE == 1 \
    || SERVICE_NEEDS_START == 1 || SERVICE_NEEDS_ENABLE == 1 \
    || FW_NEEDS_CHANGE == 1 || MIGRATING == 1)); then
    any_change=1
  fi

  if ((any_change == 0)); then
    verify_effective_unit
    info "配置、服务和防火墙均已符合目标；未重启、未新增备份"
    warn "密码按你的要求显示，可能保留在终端滚屏或会话记录中"
    print_summary "状态正常，无变更"
    if [[ "$FW_RESULT" == "ufw-missing" \
      || "$FW_RESULT" == "prepared-ufw-inactive" \
      || "$FW_RESULT" == "disabled" ]]; then
      warn "UFW 未实际保护该端口；请自行确认系统防火墙"
    fi
    if [[ "$FW_REQUESTED" == "restricted" ]]; then
      warn "--allow-from 只管理本脚本的 UFW 用户规则；自定义规则和云防火墙仍需你单独审查"
    fi
    warn "本机监听正常不等于公网可达；还需确认云安全组放行 IPv4 TCP+UDP $PORT"
    return
  fi

  begin_transaction
  start_and_verify_service
  reconcile_firewall
  write_state

  commit_transaction
  prune_backups || warn "部署已成功，但旧备份清理失败"

  if ((MIGRATING == 1)); then
    warn "已禁用旧服务 $LEGACY_SERVICE；旧配置保留为 root:root 0600"
    warn "v1.1 的旧 UFW 规则没有可靠所有权记录，未自动删除，请人工检查 ufw show added"
  fi

  warn "密码按你的要求显示，可能保留在终端滚屏或会话记录中"
  print_summary "部署成功"
  if [[ "$FW_RESULT" == "ufw-missing" || "$FW_RESULT" == "prepared-ufw-inactive" \
    || "$FW_RESULT" == "disabled" ]]; then
    warn "UFW 未实际保护该端口；请自行确认系统防火墙"
  fi
  if [[ "$FW_REQUESTED" == "restricted" ]]; then
    warn "--allow-from 只管理本脚本的 UFW 用户规则；自定义规则和云防火墙仍需你单独审查"
  fi
  warn "本机监听正常不等于公网可达；还需确认云安全组放行 IPv4 TCP+UDP $PORT"
  info "失败回滚备份位于 $BACKUP_SESSION；脚本只保留最近 5 份"
}

main() {
  require_root
  validate_early_options
  create_workdir

  if ((DRY_RUN == 1)); then
    command -v openssl >/dev/null 2>&1 || die "dry-run 需要 openssl"
    command -v curl >/dev/null 2>&1 || die "dry-run 需要 curl"
    command -v jq >/dev/null 2>&1 || die "dry-run 需要 jq"
    dry_run
    return
  fi

  check_platform
  acquire_lock
  preflight_existing_directories
  cleanup_stale_managed_temps
  install_dependencies
  deploy
}

main
