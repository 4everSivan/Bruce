#!/usr/bin/env bash
set -euo pipefail

# 用途: 独立测试 StepFun Step Plan 接口能否正常获取数据
# 用法: ./scripts/test-stepfun-token.sh <OASIS_TOKEN>

if [ -z "${1:-}" ]; then
  echo "用法: $0 <OASIS_TOKEN>"
  echo "说明: 请传入从浏览器或控制台获取的有效 Oasis-Token 进行实测"
  exit 1
fi

TOKEN="$1"

# 清洗 token
TOKEN="${TOKEN#\"}"
TOKEN="${TOKEN%\"}"
TOKEN="${TOKEN#Bearer }"
TOKEN="${TOKEN#Oasis-Token=}"

# 自动从 Token 中提取绑定的 device_id 与 app_id
EXTRACTED=$(python3 -c '
import sys, base64, json
token = sys.argv[1]
parts = token.split("...")
target_jwt = parts[-1] if len(parts) > 1 else parts[0]
jwt_parts = target_jwt.split(".")
did, app_id = "", ""
if len(jwt_parts) >= 2:
    payload_b64 = jwt_parts[1]
    payload_b64 += "=" * ((4 - len(payload_b64) % 4) % 4)
    try:
        data = json.loads(base64.urlsafe_b64decode(payload_b64).decode("utf-8"))
        did = str(data.get("device_id") or "")
        app_id = str(data.get("app_id") or "")
    except Exception:
        pass
print(f"{did}|{app_id}")
' "$TOKEN" 2>/dev/null || true)

DID="${EXTRACTED%%|*}"
APP_ID="${EXTRACTED##*|}"

if [ "$APP_ID" = "20700" ]; then
  SITE_NAME="国际站 (stepfun.ai)"
  BASE_DOMAIN="platform.stepfun.ai"
  APP_ID="20700"
  LANG="en-US"
else
  SITE_NAME="国内站 (stepfun.com)"
  BASE_DOMAIN="platform.stepfun.com"
  APP_ID="10300"
  LANG="zh-CN"
fi

echo "正在向 StepFun ${SITE_NAME} 测试 Step Plan 配额接口..."
echo "接口 URL: https://${BASE_DOMAIN}/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit"
if [ -n "$DID" ]; then
  echo "自动提取到绑定的设备指纹 (Oasis-Webid): ${DID:0:8}..."
else
  echo "未在 Token 中找到绑定的 device_id"
fi

RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST \
  "https://${BASE_DOMAIN}/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -H "Origin: https://${BASE_DOMAIN}" \
  -H "Referer: https://${BASE_DOMAIN}/" \
  -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36" \
  -H "Oasis-Token: ${TOKEN}" \
  -H "Oasis-appID: ${APP_ID}" \
  -H "Oasis-Platform: web" \
  -H "Oasis-Language: ${LANG}" \
  ${DID:+-H "Oasis-Webid: ${DID}"} \
  -H "Cookie: Oasis-Token=${TOKEN}" \
  -d "{}")

HTTP_BODY=$(echo "$RESPONSE" | sed '$d')
HTTP_STATUS=$(echo "$RESPONSE" | tail -n1 | sed 's/HTTP_STATUS://')

echo "----------------------------------------"
echo "HTTP 状态码: $HTTP_STATUS"
echo "响应 Body:"
echo "$HTTP_BODY"
echo "----------------------------------------"

if [ "$HTTP_STATUS" = "200" ]; then
  echo "🎉 实测成功！成功获取到 StepFun Step Plan 配额数据！"
  exit 0
else
  echo "❌ 测试失败，HTTP 状态码: $HTTP_STATUS"
  exit 1
fi
