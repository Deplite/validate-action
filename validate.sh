#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_VERSION="v0.1.0"
readonly RELEASE_BASE="https://github.com/Deplite/agent/releases/download"

usage() {
  cat <<'EOF'
사용법: ./validate.sh (--path DIR | --files "FILE... 또는 파일 목록") [--agent-version VERSION]

--path           워크플로우 디렉토리
--files          검사할 파일 목록 (공백 또는 줄바꿈으로 구분)
--agent-version  Deplite Agent 버전 (기본값: v0.1.0)
EOF
}

fail() {
  printf '오류: %s\n' "$1" >&2
  exit 2
}

path_input=""
files_input=""
agent_version="$DEFAULT_VERSION"

while (($# > 0)); do
  case "$1" in
    --path)
      (($# >= 2)) || fail "--path 뒤에 디렉토리를 지정해주세요."
      path_input=$2
      shift 2
      ;;
    --files)
      (($# >= 2)) || fail "--files 뒤에 파일 목록을 지정해주세요."
      files_input=$2
      shift 2
      ;;
    --agent-version)
      (($# >= 2)) || fail "--agent-version 뒤에 버전을 지정해주세요."
      agent_version=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "알 수 없는 인자입니다: $1"
      ;;
  esac
done

has_path=false
has_files=false
[[ -n "$path_input" ]] && has_path=true
[[ -n "$files_input" ]] && has_files=true
if [[ "$has_path" == "$has_files" ]]; then
  fail "--path 또는 --files 중 하나만 지정해주세요."
fi

if [[ ! "$agent_version" =~ ^v?[0-9A-Za-z][0-9A-Za-z.+_-]*$ ]]; then
  fail "Agent 버전 형식이 올바르지 않습니다: $agent_version"
fi
if [[ "$agent_version" == v* ]]; then
  version_tag=$agent_version
  asset_version=${agent_version#v}
else
  version_tag="v$agent_version"
  asset_version=$agent_version
fi

os_name=$(uname -s)
case "$os_name" in
  Linux)
    asset_os=linux
    ;;
  Darwin)
    asset_os=darwin
    ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    fail "Windows 러너는 지원하지 않습니다. Linux 또는 macOS 러너를 사용해주세요."
    ;;
  *)
    fail "지원하지 않는 운영체제입니다: $os_name"
    ;;
esac

case "$(uname -m)" in
  x86_64|amd64)
    asset_arch=amd64
    ;;
  arm64|aarch64)
    asset_arch=arm64
    ;;
  *)
    fail "지원하지 않는 CPU 아키텍처입니다: $(uname -m)"
    ;;
esac

asset="deplite-agent_${asset_version}_${asset_os}_${asset_arch}.tar.gz"
download_url="$RELEASE_BASE/$version_tag/$asset"

workspace=${GITHUB_WORKSPACE:-$PWD}
if [[ ! -d "$workspace" ]]; then
  fail "워크스페이스 디렉토리를 찾을 수 없습니다: $workspace"
fi
workspace=$(cd "$workspace" && pwd -P)

repo_relative_path() {
  local candidate normalized workspace_root component
  local -a parts=() segments=()

  if [[ "$1" == /* ]]; then
    candidate=$1
  else
    candidate="${workspace%/}/$1"
  fi

  local IFS=/
  read -r -a segments <<< "${candidate#/}"
  for component in "${segments[@]}"; do
    case "$component" in
      ""|.)
        ;;
      ..)
        if ((${#parts[@]} > 0)); then
          parts=("${parts[@]:0:$(( ${#parts[@]} - 1 ))}")
        fi
        ;;
      *)
        parts+=("$component")
        ;;
    esac
  done

  normalized=""
  for component in "${parts[@]}"; do
    normalized="$normalized/$component"
  done
  [[ -n "$normalized" ]] || normalized=/

  workspace_root=${workspace%/}
  if [[ -z "$workspace_root" ]]; then
    normalized=${normalized#/}
    printf '%s\n' "${normalized:-.}"
  elif [[ "$normalized" == "$workspace_root" ]]; then
    printf '.\n'
  elif [[ "$normalized" == "$workspace_root/"* ]]; then
    printf '%s\n' "${normalized#"$workspace_root/"}"
  else
    return 1
  fi
}

if [[ "$has_path" == true ]]; then
  if ! relative_path=$(repo_relative_path "$path_input"); then
    fail "검사 경로는 저장소 안에 있어야 합니다."
  fi
  [[ "$relative_path" == -* ]] && relative_path="./$relative_path"
else
  files=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_files=()
    IFS=$' \t' read -r -a line_files <<< "$line"
    for file in "${line_files[@]}"; do
      if ! relative_file=$(repo_relative_path "$file"); then
        fail "검사 파일은 저장소 안에 있어야 합니다."
      fi
      [[ "$relative_file" == -* ]] && relative_file="./$relative_file"
      files+=("$relative_file")
    done
  done <<< "$files_input"
  ((${#files[@]} > 0)) || fail "--files에 파일을 하나 이상 지정해주세요."
fi

temp_root=$(mktemp -d "${TMPDIR:-/tmp}/deplite-validate.XXXXXX")
matcher_owner=""
stop_commands_token=""
# shellcheck disable=SC2329
cleanup() {
  if [[ -n "$stop_commands_token" ]]; then
    printf '::%s::\n' "$stop_commands_token"
  fi
  if [[ -n "$matcher_owner" ]]; then
    printf '::remove-matcher owner=%s::\n' "$matcher_owner"
  fi
  rm -rf "$temp_root"
}
trap cleanup EXIT

cache_dir=""
if [[ -n "${RUNNER_TOOL_CACHE:-}" ]]; then
  cache_dir="$RUNNER_TOOL_CACHE/deplite-agent/$version_tag/$asset_os-$asset_arch"
  mkdir -p "$cache_dir"
fi

archive="$temp_root/$asset"
if [[ -n "$cache_dir" && -f "$cache_dir/$asset" ]]; then
  archive="$cache_dir/$asset"
else
  curl --fail --silent --show-error --location --retry 2 --retry-delay 1 \
    --output "$archive" "$download_url" || fail "Agent를 다운로드하지 못했습니다: $download_url"
  if [[ -n "$cache_dir" ]]; then
    mv "$archive" "$cache_dir/$asset"
    archive="$cache_dir/$asset"
  fi
fi

if [[ "$version_tag" == "$DEFAULT_VERSION" ]]; then
  case "$asset" in
    deplite-agent_0.1.0_darwin_amd64.tar.gz)
      expected="96603576e944ea8158b7fff4360ae90ac340147a696eb65549f25129317ad99f"
      ;;
    deplite-agent_0.1.0_darwin_arm64.tar.gz)
      expected="e9e03b5747e592cd63ba50129fbd4fa6d0491d96606a8992e0f58a4b27ea7e18"
      ;;
    deplite-agent_0.1.0_linux_amd64.tar.gz)
      expected="34ce8e178e869fcb03a92347679554662f741122fa259b6450fc04e7ed69b84e"
      ;;
    deplite-agent_0.1.0_linux_arm64.tar.gz)
      expected="f7a5d7b52a373646ad56ac75247f03dd1f2276e09f604d98a473b1441d82a6ae"
      ;;
    *)
      fail "고정된 v0.1.0 체크섬을 찾을 수 없습니다: $asset"
      ;;
  esac
else
  checksum_file="$temp_root/checksums.txt"
  curl --fail --silent --show-error --location --retry 2 --retry-delay 1 \
    --output "$checksum_file" "$RELEASE_BASE/$version_tag/checksums.txt" \
    || fail "Agent checksums.txt를 다운로드하지 못했습니다: $version_tag"
  expected=$(awk -v asset="$asset" '$2 == asset { print $1 }' "$checksum_file")
  if [[ ! "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then
    fail "checksums.txt에서 $asset의 SHA-256을 찾지 못했습니다."
  fi
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$archive" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 "$archive" | awk '{print $1}')
else
  fail "SHA-256 검증 도구(sha256sum 또는 shasum)가 필요합니다."
fi
expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
if [[ "$actual" != "$expected" ]]; then
  [[ -n "$cache_dir" ]] && rm -f "$cache_dir/$asset"
  fail "Agent 파일의 SHA-256 검증에 실패했습니다: $asset"
fi

agent_dir="$temp_root/agent"
mkdir -p "$agent_dir"
if ! tar -xzf "$archive" -C "$agent_dir"; then
  fail "Agent 압축 파일을 풀지 못했습니다: $asset"
fi
agent_bin="$agent_dir/deplite-agent"
if [[ ! -f "$agent_bin" ]]; then
  fail "Agent 압축 파일에 실행 파일이 없습니다: deplite-agent"
fi
chmod +x "$agent_bin"

cd "$workspace"
if [[ -n "${GITHUB_ACTION_PATH:-}" && -n "${GITHUB_WORKSPACE:-}" ]]; then
  matcher_owner=deplite-validate
  printf '::add-matcher::%s/problem-matcher.json\n' "$GITHUB_ACTION_PATH"
  if ! stop_commands_token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') \
    || [[ ! "$stop_commands_token" =~ ^[[:xdigit:]]{32}$ ]]; then
    fail "출력 보호 토큰을 만들지 못했습니다."
  fi
  printf '::stop-commands::%s\n' "$stop_commands_token"
fi

normalize_agent_output() {
  awk -v root="${workspace%/}/" '
    /^FAIL  / {
      prefix = "FAIL  " root
      if (index($0, prefix) == 1) {
        $0 = "FAIL  " substr($0, length(prefix) + 1)
      }
    }
    { print }
  '
}

if [[ "$has_path" == true ]]; then
  if "$agent_bin" validate --workflows-dir "$relative_path" 2>&1 | normalize_agent_output; then
    exit 0
  else
    exit "$?"
  fi
else
  if "$agent_bin" validate "${files[@]}" 2>&1 | normalize_agent_output; then
    exit 0
  else
    exit "$?"
  fi
fi
