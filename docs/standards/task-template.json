{
  "$schema": "https://ad-flow.org/schemas/task-card.v1.json",
  "id": "T[01~99]",
  "title": "简述任务目标",
  "version": "",
  "milestone": "M[1~99]-里程碑名",
  "status": "pending",
  "branch": "feat/T[01~99]-[short-desc]",
  "depends_on": [],

  "target": {
    "module": "模块名",
    "design_doc": "docs/devel/design/01-系统核心设计方案.md",
    "design_topic": "CoreService"
  },

  "goal": "说明本任务需要实现的领域能力与核心业务诉求。",

  "precheck": {
    "description": "预检当前任务是否已在代码库中实现或已满足完成条件",
    "command": "",
    "expected": "",
    "is_completed": false,
    "evidence": ""
  },

  "callback": {
    "before": [
      "# 任务执行前脚本或流程，如环境预热、分支准备、数据预加载等"
    ],
    "after": [
      "# 任务执行后脚本或流程，如代码格式化、静态检查、构建打包等",
      "scripts/adflow-verify  # 收口前门禁：Exit 4 禁止置 completed；目标状态预检使用 --card <本卡号> --to <目标状态> --record，仅回写本卡 gate，Exit 0 后再同步状态，并以 --card <本卡号> --receipt 复核、输出节点回执"
    ]
  },

  "tasks": [
    {
      "id": "T01-1",
      "title": "子任务标题",
      "capability": "说明交付的具体能力、纯数据结构或接口签名",
      "done": false
    }
  ],

  "acceptance": {
    "result": null,
    "run_id": "",
    "checks": [
      {
        "item": "架构纯度与边界",
        "true_if": "模块遵循分层设计，零不当反向依赖与架构污染",
        "false_if": "检测到跨层耦合或违规调用",
        "evidence": "",
        "result": null
      },
      {
        "item": "规则覆盖度",
        "true_if": "设计方案定义的所有业务场景在用例中全量覆盖",
        "false_if": "遗漏任一核心分支或断言",
        "evidence": "",
        "result": null
      }
    ]
  },
  "sync": {
    "commit": ""
  },
  "gate": {
    "tool": "adflow-verify",
    "version": "1.5.0",
    "ran_at": "",
    "exit_code": null
  }
}
