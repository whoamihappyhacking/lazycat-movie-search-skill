#!/usr/bin/env bash
set -euo pipefail

VUETORRENT_PKG_ID="${VUETORRENT_PKG_ID:-cloud.lazycat.app.vuetorrent}"
BASE_URL="${VUETORRENT_URL:-http://app.${VUETORRENT_PKG_ID}.lzcx}"
USERNAME="${VUETORRENT_USERNAME:-admin}"
PASSWORD="${VUETORRENT_PASSWORD:-adminadmin}"
HC_USER_TICKET="${HC_USER_TICKET:-${X_HC_USER_TICKET:-${LZC_HC_USER_TICKET:-}}}"
HC_AUTH_TOKEN="${HC_AUTH_TOKEN:-}"
COOKIE_JAR="${VUETORRENT_COOKIE_JAR:-${TMPDIR:-/tmp}/vuetorrent-api.sid}"
DEFAULT_UP_LIMIT_BYTES=131072
OUTPUT="summary"

usage() {
  cat <<'EOF'
VueTorrent / qBittorrent 控制脚本

说明：
  单文件 Bash 脚本，用于访问 VueTorrent 背后的 qBittorrent Web API。
  支持登录、列出任务、添加 magnet/.torrent，并检查全局上传限速。

默认配置：
  VUETORRENT_PKG_ID    cloud.lazycat.app.vuetorrent
  VUETORRENT_URL       http://app.<VUETORRENT_PKG_ID>.lzcx
  VUETORRENT_USERNAME  admin
  VUETORRENT_PASSWORD  adminadmin
  HC_USER_TICKET       应用互访使用的 X-HC-USER-TICKET

懒猫应用互访：
  标准地址是 http://app.<target-pkg-id>.lzcx，不是 vuetorrent.<微服名>.heiyu.space。
  如果访问失败，请传入 --user-ticket，并检查 VueTorrent 是否已安装、已启动。

用法：
  ./vuetorrent-api.sh [global options] login [login options]
  ./vuetorrent-api.sh [global options] list [all|downloading|completed|active|paused]
  ./vuetorrent-api.sh [global options] add MAGNET_OR_URL [options]
  ./vuetorrent-api.sh add-file FILE.torrent [options]
  ./vuetorrent-api.sh upload-limit

命令：
  login                         登录并保存 SID cookie
  list                          列出任务，默认 all
  downloading                   列出下载中的任务
  completed                     列出已完成任务
  add MAGNET_OR_URL             添加 magnet 或远程 .torrent URL
  add-file FILE.torrent         添加本地 .torrent 文件
  upload-limit                  获取上传限速；未设置则自动设置为 128 KiB/s
  maindata                      输出 /sync/maindata 摘要

全局 / 登录参数：
  --url URL                     VueTorrent 地址
  --pkg-id PKG_ID               VueTorrent 应用 package id，生成 http://app.<pkg-id>.lzcx
  --username NAME               登录用户名
  --password PASS               登录密码
  --user-ticket TICKET          X-HC-USER-TICKET
  --hc-token TOKEN              兼容旧测试入口的 HC-Auth-Token cookie
  --cookie-jar PATH             SID cookie 保存路径

添加参数：
  --no-sequential               添加时不启用顺序下载
  --paused                      添加后暂停
  --save-path PATH              保存路径
  --category NAME               分类
  --tags TEXT                   标签，多个标签用逗号分隔

输出参数：
  --json                        输出原始 JSON
  -h, --help                    显示帮助

依赖：
  bash、curl、jq

示例：
  ./vuetorrent-api.sh login
  ./vuetorrent-api.sh login --pkg-id cloud.lazycat.app.vuetorrent --user-ticket '<ticket>'
  ./vuetorrent-api.sh --pkg-id cloud.lazycat.app.vuetorrent --user-ticket '<ticket>' list
  ./vuetorrent-api.sh --url 'http://app.cloud.lazycat.app.vuetorrent.lzcx' list
  ./vuetorrent-api.sh list downloading
  ./vuetorrent-api.sh completed
  ./vuetorrent-api.sh add 'magnet:?xt=urn:btih:...' --save-path /root/Downloads
  ./vuetorrent-api.sh add-file ./movie.torrent
  ./vuetorrent-api.sh upload-limit

配置示例：
  VUETORRENT_PKG_ID='cloud.lazycat.app.vuetorrent' HC_USER_TICKET='<ticket>' ./vuetorrent-api.sh list
  VUETORRENT_USERNAME=admin VUETORRENT_PASSWORD=adminadmin ./vuetorrent-api.sh login
EOF
}

die() {
  printf '错误：%s\n\n' "$*" >&2
  usage >&2
  exit 2
}

need_value() {
  local opt="${1:-}"
  local val="${2:-}"
  [[ -n "$val" && "$val" != --* ]] || die "$opt 需要一个值"
}

apply_global_option() {
  case "$1" in
    --url) need_value "$1" "${2:-}"; BASE_URL="$2"; return 0 ;;
    --pkg-id) need_value "$1" "${2:-}"; VUETORRENT_PKG_ID="$2"; BASE_URL="http://app.${VUETORRENT_PKG_ID}.lzcx"; return 0 ;;
    --username) need_value "$1" "${2:-}"; USERNAME="$2"; return 0 ;;
    --password) need_value "$1" "${2:-}"; PASSWORD="$2"; return 0 ;;
    --user-ticket) need_value "$1" "${2:-}"; HC_USER_TICKET="$2"; return 0 ;;
    --hc-token) need_value "$1" "${2:-}"; HC_AUTH_TOKEN="$2"; return 0 ;;
    --cookie-jar) need_value "$1" "${2:-}"; COOKIE_JAR="$2"; return 0 ;;
    *) return 1 ;;
  esac
}

parse_global_options() {
  while (($#)); do
    case "$1" in
      --url|--pkg-id|--username|--password|--user-ticket|--hc-token|--cookie-jar)
        apply_global_option "$1" "${2:-}"
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done
  REMAINING_ARGS=("$@")
}

parse_login_options() {
  while (($#)); do
    case "$1" in
      --url|--pkg-id|--username|--password|--user-ticket|--hc-token|--cookie-jar)
        apply_global_option "$1" "${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知登录参数：$1"
        ;;
    esac
  done
}

api_url() {
  printf '%s/api/v2/%s' "${BASE_URL%/}" "$1"
}

curl_base() {
  local -a args=(-fsS -H 'accept: application/json, text/plain, */*')
  [[ -n "$HC_USER_TICKET" ]] && args+=(-H "X-HC-USER-TICKET: ${HC_USER_TICKET}")
  [[ -n "$HC_AUTH_TOKEN" ]] && args+=(-b "HC-Auth-Token=${HC_AUTH_TOKEN}")
  curl "${args[@]}" "$@"
}

login() {
  mkdir -p "$(dirname "$COOKIE_JAR")"
  local response
  response="$(
    curl_base \
      -c "$COOKIE_JAR" \
      -H 'content-type: application/x-www-form-urlencoded' \
      --data-urlencode "username=${USERNAME}" \
      --data-urlencode "password=${PASSWORD}" \
      "$(api_url auth/login)"
  )"

  [[ "$response" == "Ok." ]] || {
    printf '登录失败：%s\n' "$response" >&2
    exit 1
  }

  printf '登录成功，SID 已保存到 %s\n' "$COOKIE_JAR"
}

ensure_login() {
  if [[ ! -s "$COOKIE_JAR" ]]; then
    login >/dev/null
    return
  fi

  if ! curl_base -b "$COOKIE_JAR" "$(api_url app/version)" >/dev/null 2>&1; then
    login >/dev/null
  fi
}

api_get() {
  ensure_login
  curl_base -b "$COOKIE_JAR" "$(api_url "$1")"
}

api_post_form() {
  ensure_login
  local endpoint="$1"
  shift
  curl_base -b "$COOKIE_JAR" -X POST "$@" "$(api_url "$endpoint")"
}

human_rate() {
  local bytes="$1"
  if [[ "$bytes" == "0" || "$bytes" == "-1" ]]; then
    printf '未限制'
  elif command -v awk >/dev/null 2>&1; then
    awk -v b="$bytes" 'BEGIN {
      if (b >= 1048576) printf "%.2f MiB/s", b / 1048576;
      else printf "%.0f KiB/s", b / 1024;
    }'
  else
    printf '%s B/s' "$bytes"
  fi
}

upload_limit() {
  local prefs limit
  prefs="$(api_get app/preferences)"
  limit="$(printf '%s' "$prefs" | jq -r '.up_limit // 0')"

  if [[ "$limit" == "0" || "$limit" == "-1" ]]; then
    api_post_form app/setPreferences \
      --data-urlencode "json={\"up_limit\":${DEFAULT_UP_LIMIT_BYTES}}" >/dev/null
    printf '上传限速未设置，已自动设置为 128 KiB/s (%s B/s)\n' "$DEFAULT_UP_LIMIT_BYTES"
  else
    printf '当前上传限速：%s (%s B/s)\n' "$(human_rate "$limit")" "$limit"
  fi
}

print_torrents() {
  if [[ "$OUTPUT" == "json" ]]; then
    jq .
    return
  fi

  jq -r '
    if length == 0 then
      "没有任务。"
    else
      .[] |
      [
        "名称: " + (.name // "-"),
        "Hash: " + (.hash // "-"),
        "状态: " + (.state // "-"),
        "进度: " + (((.progress // 0) * 10000 | floor) / 100 | tostring) + "%",
        "大小: " + ((.size // 0) | tostring) + " B",
        "下载速度: " + ((.dlspeed // 0) | tostring) + " B/s",
        "上传速度: " + ((.upspeed // 0) | tostring) + " B/s",
        "Seeds/Peers: " + ((.num_seeds // 0) | tostring) + "/" + ((.num_leechs // 0) | tostring),
        "顺序下载: " + ((.seq_dl // false) | tostring),
        "保存路径: " + (.save_path // "-"),
        "Magnet: " + (.magnet_uri // "-")
      ] | join("\n"),
      ""
    end'
}

list_torrents() {
  local filter="${1:-all}"
  api_get "torrents/info?filter=${filter}" | print_torrents
}

maindata() {
  local data
  data="$(api_get sync/maindata)"
  if [[ "$OUTPUT" == "json" ]]; then
    printf '%s\n' "$data" | jq .
  else
    printf '%s\n' "$data" | jq -r '
      "连接状态: " + (.server_state.connection_status // "-"),
      "任务数量: " + (((.torrents // {}) | length) | tostring),
      "下载速度: " + ((.server_state.dl_info_speed // 0) | tostring) + " B/s",
      "上传速度: " + ((.server_state.up_info_speed // 0) | tostring) + " B/s",
      "上传限速: " + ((.server_state.up_rate_limit // 0) | tostring) + " B/s",
      "全局分享率: " + (.server_state.global_ratio // "-")'
  fi
}

parse_add_options() {
  SEQUENTIAL="true"
  PAUSED="false"
  SAVE_PATH=""
  CATEGORY=""
  TAGS=""

  while (($#)); do
    case "$1" in
      --no-sequential) SEQUENTIAL="false"; shift ;;
      --paused) PAUSED="true"; shift ;;
      --save-path) need_value "$1" "${2:-}"; SAVE_PATH="$2"; shift 2 ;;
      --category) need_value "$1" "${2:-}"; CATEGORY="$2"; shift 2 ;;
      --tags) need_value "$1" "${2:-}"; TAGS="$2"; shift 2 ;;
      --json) OUTPUT="json"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知添加参数：$1" ;;
    esac
  done
}

add_common_fields() {
  ADD_ARGS+=(-F "sequentialDownload=${SEQUENTIAL}")
  ADD_ARGS+=(-F "paused=${PAUSED}")
  [[ -n "$SAVE_PATH" ]] && ADD_ARGS+=(-F "savepath=${SAVE_PATH}")
  [[ -n "$CATEGORY" ]] && ADD_ARGS+=(-F "category=${CATEGORY}")
  [[ -n "$TAGS" ]] && ADD_ARGS+=(-F "tags=${TAGS}")
  return 0
}

add_url() {
  local url="$1"
  shift
  parse_add_options "$@"
  declare -g -a ADD_ARGS=()
  ADD_ARGS+=(-F "urls=${url}")
  add_common_fields
  api_post_form torrents/add "${ADD_ARGS[@]}"
  printf '已提交任务，顺序下载=%s\n' "$SEQUENTIAL"
}

add_file() {
  local file="$1"
  shift
  [[ -f "$file" ]] || die "找不到 torrent 文件：$file"
  parse_add_options "$@"
  declare -g -a ADD_ARGS=()
  ADD_ARGS+=(-F "torrents=@${file}")
  add_common_fields
  api_post_form torrents/add "${ADD_ARGS[@]}"
  printf '已提交 torrent 文件，顺序下载=%s\n' "$SEQUENTIAL"
}

main() {
  (($#)) || { usage; exit 0; }

  declare -a REMAINING_ARGS=()
  parse_global_options "$@"
  set -- "${REMAINING_ARGS[@]}"
  (($#)) || { usage; exit 0; }

  local command="$1"
  shift

  case "$command" in
    -h|--help)
      usage
      ;;
    --json)
      OUTPUT="json"
      (($#)) || die "--json 后需要命令"
      main "$@"
      ;;
    login)
      parse_login_options "$@"
      login
      ;;
    list)
      if [[ "${1:-}" == "--json" ]]; then
        OUTPUT="json"
        shift
      fi
      list_torrents "${1:-all}"
      ;;
    downloading)
      list_torrents downloading
      ;;
    completed)
      list_torrents completed
      ;;
    add)
      (($#)) || die "add 需要 magnet 或 URL"
      local url="$1"
      shift
      add_url "$url" "$@"
      ;;
    add-file)
      (($#)) || die "add-file 需要 .torrent 文件路径"
      local file="$1"
      shift
      add_file "$file" "$@"
      ;;
    upload-limit)
      upload_limit
      ;;
    maindata)
      if [[ "${1:-}" == "--json" ]]; then
        OUTPUT="json"
      fi
      maindata
      ;;
    *)
      die "未知命令：$command"
      ;;
  esac
}

main "$@"
