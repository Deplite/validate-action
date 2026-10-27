#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
cd "$script_dir"

test_tool_cache=$(mktemp -d "${TMPDIR:-/tmp}/deplite-validate-test.XXXXXX")
trap 'rm -rf "$test_tool_cache"' EXIT

assert_path_rejected() {
  local label=$1
  local expected_message=$2
  shift 2
  local output status

  if output=$(GITHUB_WORKSPACE="$script_dir" ./validate.sh "$@" --agent-version v0.1.0 2>&1); then
    status=0
  else
    status=$?
  fi
  if [[ "$status" -ne 2 ]] || ! grep -Fq "$expected_message" <<< "$output"; then
    printf '오류: %s 경로를 거부하지 못했습니다.\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  printf '경로 거부 확인: %s\n' "$label"
}

assert_path_rejected '상대 경로 탈출 (--path)' '검사 경로는 저장소 안에 있어야 합니다' --path ../outside
assert_path_rejected '상대 경로 탈출 (--files)' '검사 파일은 저장소 안에 있어야 합니다' --files ../outside.yml
assert_path_rejected '워크스페이스 밖 절대 경로 (--files)' '검사 파일은 저장소 안에 있어야 합니다' --files /deplite-validate-outside.yml

printf '%s\n' '유효한 워크플로우를 검사합니다.'
RUNNER_TOOL_CACHE="$test_tool_cache" ./validate.sh --path testdata/valid --agent-version v0.1.0

printf '%s\n' '잘못된 워크플로우가 실패하는지 검사합니다.'
if invalid_output=$(RUNNER_TOOL_CACHE="$test_tool_cache" ./validate.sh --path testdata/invalid --agent-version v0.1.0 2>&1); then
  printf '%s\n' "$invalid_output"
  printf '%s\n' '오류: 잘못된 워크플로우가 성공으로 처리됐습니다.' >&2
  exit 1
else
  invalid_status=$?
fi
if [[ "$invalid_status" -eq 2 ]]; then
  printf '%s\n' "$invalid_output"
  printf '%s\n' '오류: Agent 실행 전에 검사가 중단됐습니다.' >&2
  exit 1
fi
printf '%s\n' "$invalid_output"
printf '%s\n' 'test.sh 통과: valid는 성공했고 invalid는 실패했습니다.'
