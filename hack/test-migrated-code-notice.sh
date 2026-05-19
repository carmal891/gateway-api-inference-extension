#!/usr/bin/env bash
# Offline checks for migrated-code-notice.sh (no gh login required).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/.github/scripts/migrated-code-notice.sh"

if [[ ! -x "$SCRIPT" ]] && [[ ! -f "$SCRIPT" ]]; then
  echo "missing ${SCRIPT}"
  exit 1
fi

bash -n "$SCRIPT"

# Stub gh/jq: feed fake PR file lists via mocked gh api.
stub_bin="${ROOT}/.hack-migrated-notice-bin"
mkdir -p "$stub_bin"

cat > "${stub_bin}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"pulls/${PR_NUMBER}/files"* ]]; then
  case "${MOCK_PR_FILES:-}" in
    epp) echo '[{"filename":"pkg/epp/README.md"}]' ;;
    lwepp) echo '[{"filename":"pkg/lwepp/README.md"}]' ;;
    *) echo '[]' ;;
  esac
  exit 0
fi
if [[ "$*" == *"/comments"* ]]; then
  echo '[]'
  exit 0
fi
echo "unexpected gh call: $*" >&2
exit 1
STUB

cat > "${stub_bin}/jq" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "length" ]]; then
  read -r body
  if [[ "$body" == "[]" ]]; then echo 0; else echo 1; fi
  exit 0
fi
if [[ "${1:-}" == "-r" ]]; then
  read -r body
  echo "$body" | sed -n 's/.*"filename":"\([^"]*\)".*/\1/p'
  exit 0
fi
exit 0
STUB

chmod +x "${stub_bin}/gh" "${stub_bin}/jq"

run_case() {
  local name=$1 files=$2 expect=$3
  export MOCK_PR_FILES=$files
  export GITHUB_REPOSITORY=kubernetes-sigs/gateway-api-inference-extension
  export PR_NUMBER=1
  export DRY_RUN=true
  export PATH="${stub_bin}:${PATH}"

  echo "== ${name} =="
  out=$(cd "$ROOT" && bash "$SCRIPT" 2>&1) || true
  if [[ "$expect" == "comment" ]]; then
    if echo "$out" | grep -q 'llm-d-migration-notice-v1'; then
      echo "ok (would post notice)"
    else
      echo "FAIL: expected notice body"
      echo "$out"
      exit 1
    fi
  else
    if echo "$out" | grep -q 'llm-d-migration-notice-v1'; then
      echo "FAIL: unexpected notice"
      echo "$out"
      exit 1
    fi
    echo "ok (no notice)"
  fi
}

run_case "pkg/epp change" epp comment
run_case "pkg/lwepp only" lwepp skip

rm -rf "$stub_bin"
echo "All offline checks passed."
