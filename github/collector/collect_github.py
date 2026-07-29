"""采集 GitHub 贡献日历：通过本机 gh CLI 的 GraphQL API。
产出 artifact: { generatedAt, login, totalContributions, today, currentStreak,
                 longestStreak, bestDay, weeks: [{ days: [{date,count,level,weekday}] }] }
"""
import json
import subprocess
from datetime import datetime
from zoneinfo import ZoneInfo

QUERY = """
query {
  viewer {
    login
    contributionsCollection {
      contributionCalendar {
        totalContributions
        weeks {
          contributionDays { date contributionCount contributionLevel weekday }
        }
      }
    }
  }
}
"""


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


def _fetch_graphql(ctx):
    graphql = ctx.get("graphql")
    if graphql:
        return graphql(QUERY)
    runner = ctx.get("gh_runner") or subprocess.run
    proc = runner(
        [ctx.get("gh_path") or "gh", "api", "graphql", "-f", "query=%s" % QUERY],
        capture_output=True,
        text=True,
        timeout=float(ctx.get("request_timeout", 10)),
    )
    if proc.returncode != 0:
        raise RuntimeError(
            "gh api graphql 失败: %s" % (proc.stderr.strip() or proc.stdout.strip())
        )
    return json.loads(proc.stdout)


def build_artifact(payload, now_value):
    viewer = payload["data"]["viewer"]
    cal = viewer["contributionsCollection"]["contributionCalendar"]

    weeks = []
    flat = []
    for w in cal["weeks"]:
        days = []
        for d in w["contributionDays"]:
            day = {
                "date": d["date"],
                "count": d["contributionCount"],
                "level": d["contributionLevel"],
                "weekday": d["weekday"],
            }
            days.append(day)
            flat.append(day)
        weeks.append({"days": days})

    today_str = now_value.date().isoformat()
    today_count = 0
    for d in flat:
        if d["date"] == today_str:
            today_count = d["count"]
            break

    # 连续统计：仅统计有贡献的连续日期；当前连续允许今天还没贡献（从昨天起算）
    longest = 0
    cur = 0
    for d in flat:
        if d["count"] > 0:
            cur += 1
            longest = max(longest, cur)
        else:
            cur = 0
    # 当前连续：从最后一天往回数；若今天为 0，则从昨天开始也算有效
    streak = 0
    tail = flat[-1:] if flat else []
    start = len(flat) - 1
    if flat and flat[-1]["count"] == 0:
        start = len(flat) - 2
    i = start
    while i >= 0 and flat[i]["count"] > 0:
        streak += 1
        i -= 1

    best = None
    for d in flat:
        if d["count"] > 0 and (best is None or d["count"] > best["count"]):
            best = {"date": d["date"], "count": d["count"]}

    return {
        "generatedAt": now_value.isoformat(timespec="seconds"),
        "login": viewer["login"],
        "totalContributions": cal["totalContributions"],
        "today": today_count,
        "currentStreak": streak,
        "longestStreak": longest,
        "bestDay": best,
        "weeks": weeks,
    }


def run(ctx):
    ctx = ctx or {}
    return {"artifact": build_artifact(_fetch_graphql(ctx), _resolve_now(ctx))}


def main(argv=None, run_func=run):
    import argparse
    import os
    ap = argparse.ArgumentParser(description="采集 GitHub 贡献日历（依赖本机 gh CLI）")
    ap.add_argument("--out", help="把结果 JSON 原子写入指定文件（缺省打印到 stdout）")
    args = ap.parse_args(argv)
    text = json.dumps(run_func({}), ensure_ascii=False, indent=2)
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
