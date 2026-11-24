# Grok Bot 周用量缓存 fixture (T39)

`weekly-usage-x-premium.json` 取自 2026-11-24 本机 Grok Bot 1.2.3 的
`sand-client-persistence` 周用量分片（schemaVersion 3），字段与数值保持原样；该分片本身不含
账号标识与令牌，账号只出现在文件名中，fixture 未保留文件名。同一时刻维护者在 Grok Bot
「Settings → Usage & billing」核对：已用约 31%、重置于 2026-11-30 21:57（北京时间）、
X Subscription Premium（共享每周池），与本 fixture 一致。规则见
`docs/devel/design/02-订阅额度与凭据安全存储.md` 规则 18。
