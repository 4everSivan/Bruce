"""采集用户配置的私有 GitLab 事件，聚合成贡献日历。
使用 Events API（支持 after/before 过滤）分页拉取后按天聚合。
产出结构与 GitHub 贡献采集一致，Widget 逻辑可直接复用。
"""
import json
import ssl
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

DAYS = 371  # 53 周

LEVELS = ["NONE", "FIRST_QUARTILE", "SECOND_QUARTILE", "THIRD_QUARTILE", "FOURTH_QUARTILE"]


def bucket(n):
    if n <= 0:
        return 0
    if n <= 2:
        return 1
    if n <= 5:
        return 2
    if n <= 9:
        return 3
    return 4


def _resolve_now(ctx):
    timezone_value = ctx.get("timezone")
    if isinstance(timezone_value, str):
        timezone_value = ZoneInfo(timezone_value)
    if timezone_value is None:
        timezone_value = datetime.now().astimezone().tzinfo
    now_value = ctx.get("now")
    if callable(now_value):
        now_value = now_value()
    if isinstance(now_value, str):
        now_value = datetime.fromisoformat(now_value.replace("Z", "+00:00"))
    if now_value is None:
        now_value = datetime.now(timezone_value)
    if now_value.tzinfo is None:
        now_value = now_value.replace(tzinfo=timezone_value)
    return now_value.astimezone(timezone_value)


def _resolve_token(ctx):
    credentials = ctx.get("credentials") or {}
    if credentials.get("gitlab_token"):
        return credentials["gitlab_token"]
    if ctx.get("app_mode"):
        # App 模式禁止回退读取旧项目 token 文件
        raise PermissionError("App 模式缺少 gitlab_token 凭证")
    home = Path(ctx.get("home") or Path.home()).expanduser()
    paths = ctx.get("paths") or {}
    token_file = Path(
        paths.get(
            "gitlab_token",
            home / ".config" / "mddd" / "gitlab.token",
        )
    ).expanduser()
    return token_file.read_text(encoding="utf-8").strip()


def _resolve_base_url(ctx):
    raw_value = ctx.get("base_url")
    if not isinstance(raw_value, str) or not raw_value.strip():
        raise ValueError("缺少 GitLab base_url 配置")

    value = raw_value.strip()
    parsed = urllib.parse.urlsplit(value)
    try:
        parsed.port
    except ValueError as error:
        raise ValueError("GitLab base_url 包含无效端口") from error
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("GitLab base_url 必须是不含凭证、查询或片段的 HTTPS URL")

    path = parsed.path.rstrip("/")
    return urllib.parse.urlunsplit(
        ("https", parsed.netloc, path, "", "")
    )


def _ssl_context(ctx):
    injected = ctx.get("ssl_context")
    if injected is not None:
        return injected
    ca_file = ctx.get("ca_file")
    return ssl.create_default_context(cafile=ca_file)


def _event_date(value, timezone_value):
    text = value or ""
    if len(text) == 10:
        return text
    try:
        timestamp = datetime.fromisoformat(text.replace("Z", "+00:00"))
        if timestamp.tzinfo is None:
            timestamp = timestamp.replace(tzinfo=timezone_value)
        return timestamp.astimezone(timezone_value).date().isoformat()
    except (TypeError, ValueError):
        return ""


def api(ctx, ssl_context, token, path, retries=2):
    """带有限重试，容忍私有网络 / VPN 的短暂连接抖动。"""
    custom_get = ctx.get("http_get_json")
    if custom_get:
        return custom_get(path, token)
    base_url = _resolve_base_url(ctx)
    opener = ctx.get("urlopen") or urllib.request.urlopen
    timeout = float(ctx.get("request_timeout", 10))
    sleeper = ctx.get("sleep") or time.sleep
    last = None
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(
                base_url + path, headers={"PRIVATE-TOKEN": token}
            )
            with opener(req, context=ssl_context, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except (OSError, ValueError, json.JSONDecodeError) as error:
            last = error
            if attempt < retries:
                sleeper(1.5 * (attempt + 1))
    raise last


def run(ctx):
    ctx = ctx or {}
    ctx = dict(ctx)
    ctx["base_url"] = _resolve_base_url(ctx)
    token = _resolve_token(ctx)
    ssl_context = _ssl_context(ctx)
    now_value = _resolve_now(ctx)

    user = api(ctx, ssl_context, token, "/api/v4/user")
    uid = user["id"]

    # 分页拉取近一年事件
    today = now_value.date()
    after = (today - timedelta(days=DAYS - 1)).isoformat()
    per_day = {}
    page = 1
    while True:
        events = api(
            ctx,
            ssl_context,
            token,
            "/api/v4/users/%s/events?per_page=100&sort=desc&after=%s&page=%d" % (uid, after, page),
        )
        if not events:
            break
        for e in events:
            dstr = _event_date(e.get("created_at"), now_value.tzinfo)
            if dstr:
                per_day[dstr] = per_day.get(dstr, 0) + 1
        if len(events) < 100:
            break
        page += 1
        if page > 20:
            break

    # 合成 53 周（周起始对齐周日，与 GitHub 结构一致）
    start = today - timedelta(days=DAYS - 1)
    start = start - timedelta(days=(start.weekday() + 1) % 7)  # 回退到周日
    weeks = []
    flat = []
    cur = start
    while cur <= today:
        week = {"days": []}
        for wd in range(7):
            d = cur + timedelta(days=wd)
            if d > today:
                break
            cnt = per_day.get(d.isoformat(), 0)
            day = {
                "date": d.isoformat(),
                "count": cnt,
                "level": LEVELS[bucket(cnt)],
                "weekday": wd,
            }
            week["days"].append(day)
            flat.append(day)
        weeks.append(week)
        cur = cur + timedelta(days=7)

    today_str = today.isoformat()
    today_count = per_day.get(today_str, 0)

    longest = 0
    cur_streak = 0
    for d in flat:
        if d["count"] > 0:
            cur_streak += 1
            longest = max(longest, cur_streak)
        else:
            cur_streak = 0
    streak = 0
    i = len(flat) - 1
    if flat and flat[-1]["count"] == 0:
        i = len(flat) - 2
    while i >= 0 and flat[i]["count"] > 0:
        streak += 1
        i -= 1

    best = None
    for d in flat:
        if d["count"] > 0 and (best is None or d["count"] > best["count"]):
            best = {"date": d["date"], "count": d["count"]}

    return {
        "artifact": {
            "generatedAt": now_value.isoformat(timespec="seconds"),
            "login": user.get("username") or "",
            "displayName": user.get("name") or "",
            "totalContributions": sum(per_day.values()),
            "today": today_count,
            "currentStreak": streak,
            "longestStreak": longest,
            "bestDay": best,
            "weeks": weeks,
        }
    }


def main(argv=None, run_func=run):
    import argparse
    import os
    ap = argparse.ArgumentParser(
        description="采集用户配置的 GitLab 贡献日历（令牌读取自本机文件）"
    )
    ap.add_argument(
        "--base-url",
        required=True,
        help="GitLab 实例的 HTTPS base URL",
    )
    ap.add_argument("--out", help="把结果 JSON 原子写入指定文件（缺省打印到 stdout）")
    args = ap.parse_args(argv)
    text = json.dumps(
        run_func({"base_url": args.base_url}),
        ensure_ascii=False,
        indent=2,
    )
    if args.out:
        out = os.path.expanduser(args.out)
        parent = os.path.dirname(out)
        if parent:
            os.makedirs(parent, exist_ok=True)
        tmp = out + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, out)  # 原子替换，避免读取方拿到半截文件
        print("written:", out)
    else:
        print(text)


if __name__ == "__main__":
    main()
