#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-/Users/yudongrui/opt/anaconda3/bin/python3}"
DATABASE="$HOME/Library/Application Support/TouchBarCodexToken/token-usage.sqlite3"
REPORT_DIR="$HOME/Library/Application Support/TouchBarCodexToken/reports"
MAILER="${TOKEN_REPORT_MAILER:-$HOME/Documents/发送邮件/send_email.py}"
INLINE_MAILER="$ROOT_DIR/scripts/send-inline-report.py"
RECIPIENT="${TOKEN_REPORT_RECIPIENT:-1025127556@qq.com}"
MODE="${1:-daily}"

mkdir -p "$REPORT_DIR"

if [[ "$MODE" == "test" ]]; then
    LABEL="$(date '+%Y-%m-%d %H:%M')"
    SUBJECT="[测试] Codex Token 使用报告 $LABEL"
    OUTPUT="$REPORT_DIR/token-report-test-$(date '+%Y%m%d-%H%M%S').png"
    PERIOD_ARGS=()
else
    LABEL="$(date -v-1d '+%Y-%m-%d')"
    SUBJECT="Codex Token 使用日报 $LABEL"
    OUTPUT="$REPORT_DIR/token-report-$LABEL.png"
    PERIOD_ARGS=(--completed-periods)
fi

"$PYTHON_BIN" "$ROOT_DIR/scripts/generate-token-report.py" \
    --database "$DATABASE" \
    --quota "$HOME/Library/Application Support/TouchBarCodexToken/quota-status.json" \
    --output "$OUTPUT" \
    "${PERIOD_ARGS[@]}"

"$PYTHON_BIN" "$INLINE_MAILER" \
    --mailer "$MAILER" \
    --env-file "$(dirname "$MAILER")/.env" \
    --to "$RECIPIENT" \
    --subject "$SUBJECT" \
    --body "正文图片为 $LABEL 的 Codex Token 使用情况，包含额度状态、近30天每日用量和近24小时每小时用量。" \
    --image "$OUTPUT"

echo "$OUTPUT"
