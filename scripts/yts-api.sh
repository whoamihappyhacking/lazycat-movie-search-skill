#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${YTS_API_BASE_URL:-https://movies-api.accel.li/api/v2}"
FORMAT="${YTS_API_FORMAT:-json}"
OUTPUT="summary"
COMMAND=""
ENDPOINT=""
declare -a PARAMS=()

usage() {
  cat <<'EOF'
YTS 电影搜索脚本

说明：
  单文件 Bash 脚本，用于从 YTS API 搜索电影，并输出可用分辨率的
  .torrent 下载链接和 magnet 链接。

  默认 API 地址：https://movies-api.accel.li/api/v2

用法：
  ./yts-api.sh search "movie name" [options]
  ./yts-api.sh list [options]
  ./yts-api.sh details --movie-id ID|--imdb-id ID [options]

命令：
  search QUERY                  搜索电影，并显示可用种子和 magnet
  list                          按条件列出电影，并显示可用种子和 magnet
  details                       查看单部电影的种子和 magnet
  suggestions --movie-id ID     查看相关电影的种子和 magnet

搜索 / 列表参数：
  --query TEXT                  搜索关键词，等同于 --query-term
  --query-term TEXT             搜索关键词
  --limit N                     返回数量，范围 1-50；脚本默认 10
  --page N                      页码
  --quality VALUE               分辨率：480p、720p、1080p、1080p.x265、2160p、3D
  --minimum-rating N            最低 IMDb 评分，范围 0-9
  --genre VALUE                 类型，例如 action、comedy、drama
  --sort-by VALUE               排序字段：title、year、rating、peers、seeds、
                                download_count、like_count、date_added
  --order-by asc|desc           升序或降序
  --with-rt-ratings true|false  是否包含烂番茄评分

详情参数：
  --movie-id ID                 YTS 电影 ID
  --imdb-id ID                  IMDb ID，例如 tt0133093

输出参数：
  --full                        用 jq 格式化输出完整 JSON
  --raw                         输出 API 原始响应
  --format json|xml|jsonp       响应格式，默认 json
  -h, --help                    显示帮助

依赖：
  必需：bash、curl
  可选：jq；有 jq 时默认输出更清晰的摘要，也可格式化完整 JSON

默认输出：
  默认输出电影信息，以及每个可用种子的分辨率、编码、大小、Seeds、
  Peers、.torrent 链接和生成的 magnet 链接。

  search/list 如果没有指定 --limit，会自动使用 --limit 10，避免输出过多。
  如需完整 API JSON，用 --full；如需未处理的原始响应，用 --raw。

示例：
  ./yts-api.sh search "the matrix"
  ./yts-api.sh search "the matrix" --quality 1080p --limit 5
  ./yts-api.sh list --genre action --minimum-rating 7 --sort-by rating
  ./yts-api.sh details --imdb-id tt0133093
  ./yts-api.sh suggestions --movie-id 3525
  ./yts-api.sh search "alien" --full
  ./yts-api.sh search "alien" --raw
  ./yts-api.sh search "alien" --format xml

配置：
  设置 YTS_API_BASE_URL 可覆盖 API 地址。
  设置 YTS_API_FORMAT 可修改默认响应格式。
EOF
}

die() {
  printf 'Error: %s\n\n' "$*" >&2
  usage >&2
  exit 2
}

need_value() {
  local opt="${1:-}"
  local val="${2:-}"
  [[ -n "$val" && "$val" != --* ]] || die "$opt requires a value"
}

add_param() {
  PARAMS+=("$1=$2")
}

has_param() {
  local key="$1"
  local param
  for param in "${PARAMS[@]}"; do
    [[ "$param" == "$key="* ]] && return 0
  done
  return 1
}

normalize_command() {
  printf '%s' "$1" | tr '-' '_'
}

set_endpoint() {
  case "$(normalize_command "$1")" in
    search|list|list_movies) COMMAND="list"; ENDPOINT="list_movies" ;;
    details|movie_details) COMMAND="details"; ENDPOINT="movie_details" ;;
    suggestions|movie_suggestions) COMMAND="suggestions"; ENDPOINT="movie_suggestions" ;;
    *) die "unknown command: $1" ;;
  esac
}

parse_options() {
  while (($#)); do
    case "$1" in
      --format) need_value "$1" "${2:-}"; FORMAT="$2"; shift 2 ;;
      --full) OUTPUT="full"; shift ;;
      --raw) OUTPUT="raw"; shift ;;
      -h|--help) usage; exit 0 ;;
      --limit) need_value "$1" "${2:-}"; add_param limit "$2"; shift 2 ;;
      --page) need_value "$1" "${2:-}"; add_param page "$2"; shift 2 ;;
      --quality) need_value "$1" "${2:-}"; add_param quality "$2"; shift 2 ;;
      --minimum-rating) need_value "$1" "${2:-}"; add_param minimum_rating "$2"; shift 2 ;;
      --query|--query-term) need_value "$1" "${2:-}"; add_param query_term "$2"; shift 2 ;;
      --genre) need_value "$1" "${2:-}"; add_param genre "$2"; shift 2 ;;
      --sort-by) need_value "$1" "${2:-}"; add_param sort_by "$2"; shift 2 ;;
      --order-by) need_value "$1" "${2:-}"; add_param order_by "$2"; shift 2 ;;
      --with-rt-ratings) need_value "$1" "${2:-}"; add_param with_rt_ratings "$2"; shift 2 ;;
      --movie-id) need_value "$1" "${2:-}"; add_param movie_id "$2"; shift 2 ;;
      --imdb-id) need_value "$1" "${2:-}"; add_param imdb_id "$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

require_movie_id() {
  has_param movie_id || die "$COMMAND requires --movie-id"
}

validate_required_params() {
  case "$COMMAND" in
    details)
      has_param movie_id || has_param imdb_id || die "details requires --movie-id or --imdb-id"
      ;;
    suggestions)
      require_movie_id
      ;;
  esac
}

print_json_summary() {
  local jq_filter='
    def magnet($name):
      "magnet:?xt=urn:btih:" + (.hash // "") +
      "&dn=" + ($name | @uri) +
      "&tr=udp://tracker.opentrackr.org:1337/announce" +
      "&tr=udp://open.stealth.si:80/announce" +
      "&tr=udp://tracker.torrent.eu.org:451/announce" +
      "&tr=udp://tracker.bittor.pw:1337/announce";

    def torrent_lines($movie):
      if (($movie.torrents // []) | length) == 0 then
        "No torrents found."
      else
        $movie.torrents[]
        | [
            "  Quality: " + (.quality // "?") +
              " | Type: " + (.type // "-") +
              " | Codec: " + (.video_codec // "-") +
              " | Size: " + (.size // "-") +
              " | Seeds: " + ((.seeds // 0) | tostring) +
              " | Peers: " + ((.peers // 0) | tostring),
            "  Torrent: " + (.url // "-"),
            "  Magnet: " + magnet($movie.title_long // $movie.title // "YTS Movie")
          ] | join("\n")
      end;

    def movie_block:
      [
        "ID: " + (.id | tostring),
        "Title: " + (.title_long // .title // ""),
        "IMDb: " + (.imdb_code // "-"),
        "Rating: " + ((.rating // "-") | tostring),
        "URL: " + (.url // "-"),
        "Torrents:",
        torrent_lines(.)
      ] | join("\n");
  '

  case "$COMMAND" in
    list|suggestions)
      jq -r "$jq_filter"'
        if .status != "ok" then
          "ERROR: " + (.status_message // .status // "request failed")
        elif ((.data.movies // []) | length) == 0 then
          "No movies found."
        else
          (.data.movies | unique_by(.id // .imdb_code // .title_long)[] | movie_block), ""
        end'
      ;;
    details)
      jq -r "$jq_filter"'
        if .status != "ok" then
          "ERROR: " + (.status_message // .status // "request failed")
        else
          .data.movie | movie_block
        end'
      ;;
    *)
      jq -c .
      ;;
  esac
}

request() {
  local url="${BASE_URL%/}/${ENDPOINT}.${FORMAT}"
  local -a curl_args=(-fsS -G "$url")
  local param

  for param in "${PARAMS[@]}"; do
    curl_args+=(--data-urlencode "$param")
  done

  if [[ "$FORMAT" == "json" && "$OUTPUT" == "summary" ]] && command -v jq >/dev/null 2>&1; then
    curl "${curl_args[@]}" | print_json_summary
  elif [[ "$FORMAT" == "json" && "$OUTPUT" == "full" ]] && command -v jq >/dev/null 2>&1; then
    curl "${curl_args[@]}" | jq .
  else
    curl "${curl_args[@]}"
    printf '\n'
  fi
}

main() {
  (($#)) || { usage; exit 0; }

  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
  esac

  local command="$1"
  shift
  set_endpoint "$command"

  if [[ "$(normalize_command "$command")" == "search" ]] && (($#)) && [[ "$1" != --* ]]; then
    add_param query_term "$1"
    shift
  fi

  parse_options "$@"
  validate_required_params

  if [[ "$COMMAND" == "list" ]] && ! has_param limit; then
    add_param limit 10
  fi

  request
}

main "$@"
