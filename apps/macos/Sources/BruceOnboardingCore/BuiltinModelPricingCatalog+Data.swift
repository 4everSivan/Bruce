// 本文件由 scripts/gen-pricing-catalog.mjs 生成, 请勿手改 (C108)。
// 事实源: core/collector/crates/collector-domain/pricing-catalog.json (采集端计费同源);
// 修改价卡后运行 `node scripts/gen-pricing-catalog.mjs`, verify-local 以 --check 拦截漂移。

extension BuiltinModelPricingCatalog {
    public static let allModels: [BuiltinModelPricing] = [
        BuiltinModelPricing(
            modelName: "k3-agent",
            displayName: "Kimi K3 (Agent)",
            vendor: "Moonshot Kimi",
            inputPricePerMillion: 3.0,
            outputPricePerMillion: 15.0,
            cacheReadPricePerMillion: 0.3,
            defaultNote: "Kimi 官方标准包"
        ),
        BuiltinModelPricing(
            modelName: "k3",
            displayName: "Kimi K3",
            vendor: "Moonshot Kimi",
            inputPricePerMillion: 3.0,
            outputPricePerMillion: 15.0,
            cacheReadPricePerMillion: 0.3,
            defaultNote: "Kimi 官方标准包"
        ),
        BuiltinModelPricing(
            modelName: "k3-256k",
            displayName: "Kimi K3 (256k)",
            vendor: "Moonshot Kimi",
            inputPricePerMillion: 3.0,
            outputPricePerMillion: 15.0,
            cacheReadPricePerMillion: 0.3,
            defaultNote: "长上下文 256k 窗口"
        ),
        BuiltinModelPricing(
            modelName: "kimi-code",
            displayName: "Kimi Code",
            vendor: "Moonshot Kimi",
            inputPricePerMillion: 3.0,
            outputPricePerMillion: 15.0,
            cacheReadPricePerMillion: 0.3,
            defaultNote: "Kimi Code 编程补全"
        ),
        BuiltinModelPricing(
            modelName: "kimi-for-coding",
            displayName: "Kimi for Coding",
            vendor: "Moonshot Kimi",
            inputPricePerMillion: 3.0,
            outputPricePerMillion: 15.0,
            cacheReadPricePerMillion: 0.3,
            defaultNote: "Kimi 编程增强模型"
        ),
        BuiltinModelPricing(
            modelName: "kimi-k3",
            displayName: "Kimi K3 (ClinePass)",
            vendor: "Moonshot Kimi",
            inputPricePerMillion: 3.0,
            outputPricePerMillion: 15.0,
            cacheReadPricePerMillion: 0.3,
            defaultNote: "ClinePass 渠道包"
        ),
        BuiltinModelPricing(
            modelName: "gpt-6.1-sol",
            displayName: "GPT-6.1 Sol",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 4.5,
            outputPricePerMillion: 22.5,
            cacheReadPricePerMillion: 0.45,
            defaultNote: "旗舰高阶代码推理"
        ),
        BuiltinModelPricing(
            modelName: "gpt-6-sol",
            displayName: "GPT-6 Sol",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 4.0,
            outputPricePerMillion: 20.0,
            cacheReadPricePerMillion: 0.4,
            defaultNote: "旗舰代码生成大模型"
        ),
        BuiltinModelPricing(
            modelName: "gpt-6-luna",
            displayName: "GPT-6 Luna",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 0.25,
            outputPricePerMillion: 1.5,
            cacheReadPricePerMillion: 0.025,
            defaultNote: "极速轻量代码模型"
        ),
        BuiltinModelPricing(
            modelName: "gpt-5.6-luna",
            displayName: "GPT-5.6 Luna",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 0.2,
            outputPricePerMillion: 1.2,
            cacheReadPricePerMillion: 0.02,
            defaultNote: "高频极速轻量模型"
        ),
        BuiltinModelPricing(
            modelName: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 4.0,
            outputPricePerMillion: 20.0,
            cacheReadPricePerMillion: 0.4,
            defaultNote: "旗舰推理大模型"
        ),
        BuiltinModelPricing(
            modelName: "gpt-5.6-terra",
            displayName: "GPT-5.6 Terra",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 2.0,
            outputPricePerMillion: 12.0,
            cacheReadPricePerMillion: 0.2,
            defaultNote: "主力平衡型编程模型"
        ),
        BuiltinModelPricing(
            modelName: "gpt-5.4",
            displayName: "GPT-5.4",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 2.5,
            outputPricePerMillion: 15.0,
            cacheReadPricePerMillion: 0.25,
            defaultNote: "标准通用模型"
        ),
        BuiltinModelPricing(
            modelName: "gpt-5.4-mini",
            displayName: "GPT-5.4 mini",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 0.15,
            outputPricePerMillion: 0.6,
            cacheReadPricePerMillion: 0.015,
            defaultNote: "轻量高吞吐模型"
        ),
        BuiltinModelPricing(
            modelName: "gpt-5.2-codex",
            displayName: "GPT-5.2 Codex",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 1.75,
            outputPricePerMillion: 14.0,
            cacheReadPricePerMillion: 0.175,
            defaultNote: "经典专用代码模型"
        ),
        BuiltinModelPricing(
            modelName: "codex-auto-review",
            displayName: "Codex Auto Review",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 1.75,
            outputPricePerMillion: 14.0,
            cacheReadPricePerMillion: 0.175,
            defaultNote: "自动化审查分析"
        ),
        BuiltinModelPricing(
            modelName: "gpt-4o",
            displayName: "GPT-4o",
            vendor: "OpenAI",
            inputPricePerMillion: 2.5,
            outputPricePerMillion: 10.0,
            cacheReadPricePerMillion: 1.25,
            defaultNote: "多模态全能旗舰模型"
        ),
        BuiltinModelPricing(
            modelName: "gpt-4o-mini",
            displayName: "GPT-4o mini",
            vendor: "OpenAI",
            inputPricePerMillion: 0.15,
            outputPricePerMillion: 0.6,
            cacheReadPricePerMillion: 0.075,
            defaultNote: "轻量高吞吐全能模型"
        ),
        BuiltinModelPricing(
            modelName: "o1",
            displayName: "OpenAI o1",
            vendor: "OpenAI",
            inputPricePerMillion: 15.0,
            outputPricePerMillion: 60.0,
            cacheReadPricePerMillion: 7.5,
            defaultNote: "深度逻辑思考旗舰"
        ),
        BuiltinModelPricing(
            modelName: "o1-mini",
            displayName: "OpenAI o1-mini",
            vendor: "OpenAI",
            inputPricePerMillion: 1.1,
            outputPricePerMillion: 4.4,
            cacheReadPricePerMillion: 0.55,
            defaultNote: "轻量代码推理模型"
        ),
        BuiltinModelPricing(
            modelName: "o3-mini",
            displayName: "OpenAI o3-mini",
            vendor: "OpenAI",
            inputPricePerMillion: 1.1,
            outputPricePerMillion: 4.4,
            cacheReadPricePerMillion: 0.55,
            defaultNote: "最新低延迟思维推理模型"
        ),
        BuiltinModelPricing(
            modelName: "deepseek-v4.1-flash",
            displayName: "DeepSeek V4.1 Flash",
            vendor: "DeepSeek",
            inputPricePerMillion: 0.3,
            outputPricePerMillion: 1.2,
            cacheReadPricePerMillion: 0.006,
            defaultNote: "ClinePass 订阅参考价 (与官方 V4 Flash 分档)"
        ),
        BuiltinModelPricing(
            modelName: "deepseek-v4-flash",
            displayName: "DeepSeek V4 Flash",
            vendor: "DeepSeek",
            inputPricePerMillion: 0.15,
            outputPricePerMillion: 0.6,
            cacheReadPricePerMillion: 0.003,
            defaultNote: "闲时基准单价 (忙时自动按两倍核算)"
        ),
        BuiltinModelPricing(
            modelName: "deepseek-v4-pro",
            displayName: "DeepSeek V4 Pro",
            vendor: "DeepSeek",
            inputPricePerMillion: 0.66,
            outputPricePerMillion: 1.98,
            cacheReadPricePerMillion: 0.022,
            defaultNote: "深度推理主力 (非峰值价; 峰值 00:30-16:30 UTC 另计)"
        ),
        BuiltinModelPricing(
            modelName: "deepseek-r1",
            displayName: "DeepSeek R1",
            vendor: "DeepSeek",
            inputPricePerMillion: 0.55,
            outputPricePerMillion: 2.19,
            cacheReadPricePerMillion: 0.14,
            defaultNote: "开源深度思考推理"
        ),
        BuiltinModelPricing(
            modelName: "deepseek-reasoner",
            displayName: "DeepSeek Reasoner",
            vendor: "DeepSeek",
            inputPricePerMillion: 0.55,
            outputPricePerMillion: 2.19,
            cacheReadPricePerMillion: 0.14,
            defaultNote: "经典推理思考模型"
        ),
        BuiltinModelPricing(
            modelName: "deepseek-chat",
            displayName: "DeepSeek V3 (Chat)",
            vendor: "DeepSeek",
            inputPricePerMillion: 0.14,
            outputPricePerMillion: 0.28,
            cacheReadPricePerMillion: 0.014,
            defaultNote: "经典通用对话"
        ),
        BuiltinModelPricing(
            modelName: "claude-fable-5-1",
            displayName: "Claude Fable 5.1",
            vendor: "Anthropic",
            inputPricePerMillion: 10.0,
            outputPricePerMillion: 50.0,
            cacheReadPricePerMillion: 0.25,
            defaultNote: "最高能力档长程推理"
        ),
        BuiltinModelPricing(
            modelName: "claude-fable-5",
            displayName: "Claude Fable 5",
            vendor: "Anthropic",
            inputPricePerMillion: 10.0,
            outputPricePerMillion: 50.0,
            cacheReadPricePerMillion: 1.0,
            defaultNote: "上一代最高能力档"
        ),
        BuiltinModelPricing(
            modelName: "claude-opus-5-5",
            displayName: "Claude Opus 5.5",
            vendor: "Anthropic",
            inputPricePerMillion: 4.0,
            outputPricePerMillion: 20.0,
            cacheReadPricePerMillion: 0.2,
            defaultNote: "新一代高算力旗舰"
        ),
        BuiltinModelPricing(
            modelName: "claude-opus-5",
            displayName: "Claude Opus 5",
            vendor: "Anthropic",
            inputPricePerMillion: 5.0,
            outputPricePerMillion: 25.0,
            cacheReadPricePerMillion: 0.5,
            defaultNote: "上一代 Opus 旗舰"
        ),
        BuiltinModelPricing(
            modelName: "claude-opus-4-8",
            displayName: "Claude Opus 4.8",
            vendor: "Anthropic",
            inputPricePerMillion: 5.0,
            outputPricePerMillion: 25.0,
            cacheReadPricePerMillion: 0.5,
            defaultNote: "Opus 4 系列"
        ),
        BuiltinModelPricing(
            modelName: "claude-opus-4-7",
            displayName: "Claude Opus 4.7",
            vendor: "Anthropic",
            inputPricePerMillion: 5.0,
            outputPricePerMillion: 25.0,
            cacheReadPricePerMillion: 0.5,
            defaultNote: "Opus 4 系列"
        ),
        BuiltinModelPricing(
            modelName: "claude-opus-4-6",
            displayName: "Claude Opus 4.6",
            vendor: "Anthropic",
            inputPricePerMillion: 5.0,
            outputPricePerMillion: 25.0,
            cacheReadPricePerMillion: 0.5,
            defaultNote: "Opus 4 系列"
        ),
        BuiltinModelPricing(
            modelName: "claude-sonnet-5-5",
            displayName: "Claude Sonnet 5.5",
            vendor: "Anthropic",
            inputPricePerMillion: 2.0,
            outputPricePerMillion: 10.0,
            cacheReadPricePerMillion: 0.2,
            defaultNote: "现行 Sonnet 主力"
        ),
        BuiltinModelPricing(
            modelName: "claude-sonnet-5",
            displayName: "Claude Sonnet 5",
            vendor: "Anthropic",
            inputPricePerMillion: 2.0,
            outputPricePerMillion: 10.0,
            cacheReadPricePerMillion: 0.2,
            defaultNote: "Claude 5 代主力模型"
        ),
        BuiltinModelPricing(
            modelName: "claude-sonnet-4-6",
            displayName: "Claude Sonnet 4.6",
            vendor: "Anthropic",
            inputPricePerMillion: 3.0,
            outputPricePerMillion: 15.0,
            cacheReadPricePerMillion: 0.3,
            defaultNote: "Sonnet 4 系列"
        ),
        BuiltinModelPricing(
            modelName: "claude-haiku-5-5",
            displayName: "Claude Haiku 5.5",
            vendor: "Anthropic",
            inputPricePerMillion: 0.1,
            outputPricePerMillion: 0.5,
            cacheReadPricePerMillion: 0.01,
            defaultNote: "现行 Haiku (≤100K 提示档单价)"
        ),
        BuiltinModelPricing(
            modelName: "claude-haiku-4-5",
            displayName: "Claude Haiku 4.5",
            vendor: "Anthropic",
            inputPricePerMillion: 1.0,
            outputPricePerMillion: 5.0,
            cacheReadPricePerMillion: 0.1,
            defaultNote: "极速轻量补全模型"
        ),
        BuiltinModelPricing(
            modelName: "claude-3-7-sonnet",
            displayName: "Claude 3.7 Sonnet",
            vendor: "Anthropic",
            inputPricePerMillion: 3.0,
            outputPricePerMillion: 15.0,
            cacheReadPricePerMillion: 0.3,
            defaultNote: "混合思维推理主力"
        ),
        BuiltinModelPricing(
            modelName: "claude-3-5-sonnet",
            displayName: "Claude 3.5 Sonnet",
            vendor: "Anthropic",
            inputPricePerMillion: 3.0,
            outputPricePerMillion: 15.0,
            cacheReadPricePerMillion: 0.3,
            defaultNote: "经典通用编程大模型"
        ),
        BuiltinModelPricing(
            modelName: "claude-3-5-haiku",
            displayName: "Claude 3.5 Haiku",
            vendor: "Anthropic",
            inputPricePerMillion: 0.8,
            outputPricePerMillion: 4.0,
            cacheReadPricePerMillion: 0.08,
            defaultNote: "高性价比快速响应"
        ),
        BuiltinModelPricing(
            modelName: "claude-3-opus",
            displayName: "Claude 3 Opus",
            vendor: "Anthropic",
            inputPricePerMillion: 15.0,
            outputPricePerMillion: 75.0,
            cacheReadPricePerMillion: 1.5,
            defaultNote: "复杂推理与系统分析"
        ),
        BuiltinModelPricing(
            modelName: "gemini-2.0-flash",
            displayName: "Gemini 2.0 Flash",
            vendor: "Google",
            inputPricePerMillion: 0.1,
            outputPricePerMillion: 0.4,
            cacheReadPricePerMillion: 0.025,
            defaultNote: "下一代高极速多模态"
        ),
        BuiltinModelPricing(
            modelName: "gemini-2.0-flash-thinking",
            displayName: "Gemini 2.0 Flash Thinking",
            vendor: "Google",
            inputPricePerMillion: 0.1,
            outputPricePerMillion: 0.4,
            cacheReadPricePerMillion: 0.025,
            defaultNote: "实验性深度推理模型"
        ),
        BuiltinModelPricing(
            modelName: "gemini-2.0-pro",
            displayName: "Gemini 2.0 Pro",
            vendor: "Google",
            inputPricePerMillion: 1.25,
            outputPricePerMillion: 5.0,
            cacheReadPricePerMillion: 0.3,
            defaultNote: "复杂编程与推理旗舰"
        ),
        BuiltinModelPricing(
            modelName: "gemini-1.5-pro",
            displayName: "Gemini 1.5 Pro",
            vendor: "Google",
            inputPricePerMillion: 1.25,
            outputPricePerMillion: 5.0,
            cacheReadPricePerMillion: 0.3125,
            defaultNote: "百万上下文通用旗舰"
        ),
        BuiltinModelPricing(
            modelName: "gemini-1.5-flash",
            displayName: "Gemini 1.5 Flash",
            vendor: "Google",
            inputPricePerMillion: 0.075,
            outputPricePerMillion: 0.3,
            cacheReadPricePerMillion: 0.01875,
            defaultNote: "轻量低成本高吞吐"
        ),
        BuiltinModelPricing(
            modelName: "glm-5.3",
            displayName: "GLM-5.3",
            vendor: "智谱 AI (Zhipu)",
            inputPricePerMillion: 1.4,
            outputPricePerMillion: 4.4,
            cacheReadPricePerMillion: 0.26,
            defaultNote: "国产旗舰通用模型"
        ),
        BuiltinModelPricing(
            modelName: "glm-5.3-flash",
            displayName: "GLM-5.3 Flash",
            vendor: "智谱 AI (Zhipu)",
            inputPricePerMillion: 0.15,
            outputPricePerMillion: 0.5,
            cacheReadPricePerMillion: 0.015,
            defaultNote: "高吞吐量轻量模型"
        ),
        BuiltinModelPricing(
            modelName: "glm-4-plus",
            displayName: "GLM-4 Plus",
            vendor: "智谱 AI (Zhipu)",
            inputPricePerMillion: 1.4,
            outputPricePerMillion: 1.4,
            cacheReadPricePerMillion: 0.26,
            defaultNote: "高阶对话模型"
        ),
        BuiltinModelPricing(
            modelName: "glm-4-air",
            displayName: "GLM-4 Air",
            vendor: "智谱 AI (Zhipu)",
            inputPricePerMillion: 0.14,
            outputPricePerMillion: 0.14,
            cacheReadPricePerMillion: 0.014,
            defaultNote: "高性价比推理模型"
        ),
        BuiltinModelPricing(
            modelName: "glm-4-flash",
            displayName: "GLM-4 Flash",
            vendor: "智谱 AI (Zhipu)",
            inputPricePerMillion: 0.01,
            outputPricePerMillion: 0.01,
            cacheReadPricePerMillion: 0.001,
            defaultNote: "极低单价吞吐模型"
        ),
        BuiltinModelPricing(
            modelName: "glm-4-long",
            displayName: "GLM-4 Long",
            vendor: "智谱 AI (Zhipu)",
            inputPricePerMillion: 0.14,
            outputPricePerMillion: 0.14,
            cacheReadPricePerMillion: 0.014,
            defaultNote: "百万长文本模型"
        ),
        BuiltinModelPricing(
            modelName: "codegeex-4",
            displayName: "CodeGeeX-4",
            vendor: "智谱 AI (Zhipu)",
            inputPricePerMillion: 0.14,
            outputPricePerMillion: 0.14,
            defaultNote: "多语言代码生成"
        ),
        BuiltinModelPricing(
            modelName: "qwen3.8-max",
            displayName: "Qwen3.8 Max",
            vendor: "阿里通义千问",
            inputPricePerMillion: 2.0,
            outputPricePerMillion: 6.0,
            cacheReadPricePerMillion: 0.25,
            defaultNote: "新一代千问旗舰"
        ),
        BuiltinModelPricing(
            modelName: "qwen3.7-max",
            displayName: "Qwen3.7 Max",
            vendor: "阿里通义千问",
            inputPricePerMillion: 2.5,
            outputPricePerMillion: 7.5,
            cacheReadPricePerMillion: 0.5,
            defaultNote: "高算力推理大模型"
        ),
        BuiltinModelPricing(
            modelName: "qwen3.7-plus",
            displayName: "Qwen3.7 Plus",
            vendor: "阿里通义千问",
            inputPricePerMillion: 0.4,
            outputPricePerMillion: 1.6,
            cacheReadPricePerMillion: 0.04,
            defaultNote: "平衡型主力模型 (≤256K 输入价; 超长上下文另计)"
        ),
        BuiltinModelPricing(
            modelName: "qwen-max",
            displayName: "Qwen Max",
            vendor: "阿里通义千问",
            inputPricePerMillion: 2.8,
            outputPricePerMillion: 8.4,
            cacheReadPricePerMillion: 0.28,
            defaultNote: "官方通义千问旗舰"
        ),
        BuiltinModelPricing(
            modelName: "qwen-plus",
            displayName: "Qwen Plus",
            vendor: "阿里通义千问",
            inputPricePerMillion: 0.56,
            outputPricePerMillion: 1.68,
            cacheReadPricePerMillion: 0.056,
            defaultNote: "官方通义千问增强"
        ),
        BuiltinModelPricing(
            modelName: "qwen-turbo",
            displayName: "Qwen Turbo",
            vendor: "阿里通义千问",
            inputPricePerMillion: 0.04,
            outputPricePerMillion: 0.12,
            cacheReadPricePerMillion: 0.004,
            defaultNote: "极速轻量对话"
        ),
        BuiltinModelPricing(
            modelName: "qwen-2.5-coder-32b",
            displayName: "Qwen 2.5 Coder 32B",
            vendor: "阿里通义千问",
            inputPricePerMillion: 0.2,
            outputPricePerMillion: 0.6,
            cacheReadPricePerMillion: 0.02,
            defaultNote: "开源最强代码模型"
        ),
        BuiltinModelPricing(
            modelName: "qwen-2.5-coder-7b",
            displayName: "Qwen 2.5 Coder 7B",
            vendor: "阿里通义千问",
            inputPricePerMillion: 0.05,
            outputPricePerMillion: 0.15,
            cacheReadPricePerMillion: 0.005,
            defaultNote: "轻量代码补全"
        ),
        BuiltinModelPricing(
            modelName: "doubao-pro-128k",
            displayName: "Doubao Pro 128k",
            vendor: "字节豆包",
            inputPricePerMillion: 0.7,
            outputPricePerMillion: 1.4,
            cacheReadPricePerMillion: 0.07,
            defaultNote: "长上下文旗舰模型"
        ),
        BuiltinModelPricing(
            modelName: "doubao-pro-32k",
            displayName: "Doubao Pro 32k",
            vendor: "字节豆包",
            inputPricePerMillion: 0.11,
            outputPricePerMillion: 0.28,
            cacheReadPricePerMillion: 0.011,
            defaultNote: "标准专业模型"
        ),
        BuiltinModelPricing(
            modelName: "doubao-lite-128k",
            displayName: "Doubao Lite 128k",
            vendor: "字节豆包",
            inputPricePerMillion: 0.04,
            outputPricePerMillion: 0.14,
            cacheReadPricePerMillion: 0.004,
            defaultNote: "轻量长文本模型"
        ),
        BuiltinModelPricing(
            modelName: "doubao-lite-32k",
            displayName: "Doubao Lite 32k",
            vendor: "字节豆包",
            inputPricePerMillion: 0.04,
            outputPricePerMillion: 0.08,
            cacheReadPricePerMillion: 0.004,
            defaultNote: "极速轻量模型"
        ),
        BuiltinModelPricing(
            modelName: "hy4-preview",
            displayName: "Hunyuan 4 Preview",
            vendor: "腾讯混元",
            inputPricePerMillion: 0.85,
            outputPricePerMillion: 2.55,
            cacheReadPricePerMillion: 0.08,
            defaultNote: "新一代大语言模型 (~6.0/18.0 CNY)"
        ),
        BuiltinModelPricing(
            modelName: "hy3",
            displayName: "Hunyuan 3",
            vendor: "腾讯混元",
            inputPricePerMillion: 0.15,
            outputPricePerMillion: 0.6,
            cacheReadPricePerMillion: 0.015,
            defaultNote: "腾讯混元基础模型 (~1.0/4.0 CNY)"
        ),
        BuiltinModelPricing(
            modelName: "hy3-x",
            displayName: "Hunyuan 3X",
            vendor: "腾讯混元",
            inputPricePerMillion: 0.25,
            outputPricePerMillion: 0.75,
            cacheReadPricePerMillion: 0.025,
            defaultNote: "混元扩展增强模型"
        ),
        BuiltinModelPricing(
            modelName: "step-5-preview",
            displayName: "Step-5 Preview",
            vendor: "阶跃星辰 (StepFun)",
            inputPricePerMillion: 1.0,
            outputPricePerMillion: 2.7,
            cacheReadPricePerMillion: 0.05,
            defaultNote: "阶跃新一代旗舰推理"
        ),
        BuiltinModelPricing(
            modelName: "step-3.7-flash",
            displayName: "Step-3.7 Flash",
            vendor: "阶跃星辰 (StepFun)",
            inputPricePerMillion: 0.2,
            outputPricePerMillion: 1.15,
            cacheReadPricePerMillion: 0.03,
            defaultNote: "高性价比编程模型"
        ),
        BuiltinModelPricing(
            modelName: "step-2-16k",
            displayName: "Step-2 16k",
            vendor: "阶跃星辰 (StepFun)",
            inputPricePerMillion: 5.3,
            outputPricePerMillion: 10.0,
            cacheReadPricePerMillion: 0.5,
            defaultNote: "阶跃万亿参数推理"
        ),
        BuiltinModelPricing(
            modelName: "step-1-8k",
            displayName: "Step-1 8k",
            vendor: "阶跃星辰 (StepFun)",
            inputPricePerMillion: 0.7,
            outputPricePerMillion: 1.4,
            cacheReadPricePerMillion: 0.07,
            defaultNote: "阶跃通用多模态"
        ),
        BuiltinModelPricing(
            modelName: "grok-3",
            displayName: "Grok 3",
            vendor: "xAI",
            inputPricePerMillion: 3.0,
            outputPricePerMillion: 15.0,
            cacheReadPricePerMillion: 0.75,
            defaultNote: "全功能推理模型"
        ),
        BuiltinModelPricing(
            modelName: "grok-3-mini",
            displayName: "Grok 3 Mini",
            vendor: "xAI",
            inputPricePerMillion: 0.3,
            outputPricePerMillion: 1.5,
            cacheReadPricePerMillion: 0.075,
            defaultNote: "极速思考模型"
        ),
        BuiltinModelPricing(
            modelName: "grok-2",
            displayName: "Grok 2",
            vendor: "xAI",
            inputPricePerMillion: 2.0,
            outputPricePerMillion: 10.0,
            cacheReadPricePerMillion: 0.5,
            defaultNote: "经典通用模型"
        ),
        BuiltinModelPricing(
            modelName: "minimax-m3",
            displayName: "MiniMax M3",
            vendor: "MiniMax",
            inputPricePerMillion: 0.3,
            outputPricePerMillion: 1.2,
            cacheReadPricePerMillion: 0.06,
            defaultNote: "高智能推理模型"
        ),
        BuiltinModelPricing(
            modelName: "abab6.5s",
            displayName: "MiniMax Abab 6.5s",
            vendor: "MiniMax",
            inputPricePerMillion: 0.14,
            outputPricePerMillion: 0.28,
            cacheReadPricePerMillion: 0.014,
            defaultNote: "极速对话模型"
        ),
        BuiltinModelPricing(
            modelName: "mimo-v2.5",
            displayName: "MiMo V2.5",
            vendor: "小米 (Xiaomi)",
            inputPricePerMillion: 0.14,
            outputPricePerMillion: 0.28,
            cacheReadPricePerMillion: 0.0028,
            defaultNote: "小米高效大模型"
        ),
        BuiltinModelPricing(
            modelName: "mimo-v2.5-pro",
            displayName: "MiMo V2.5 Pro",
            vendor: "小米 (Xiaomi)",
            inputPricePerMillion: 1.74,
            outputPricePerMillion: 3.48,
            cacheReadPricePerMillion: 0.0145,
            defaultNote: "小米旗舰推理模型"
        ),
        BuiltinModelPricing(
            modelName: "yi-lightning",
            displayName: "Yi Lightning",
            vendor: "零一万物 (01.AI)",
            inputPricePerMillion: 0.14,
            outputPricePerMillion: 0.28,
            cacheReadPricePerMillion: 0.014,
            defaultNote: "超高性价比推理"
        ),
        BuiltinModelPricing(
            modelName: "yi-large",
            displayName: "Yi Large",
            vendor: "零一万物 (01.AI)",
            inputPricePerMillion: 2.8,
            outputPricePerMillion: 2.8,
            cacheReadPricePerMillion: 0.28,
            defaultNote: "千亿参数旗舰模型"
        ),
        BuiltinModelPricing(
            modelName: "baichuan-4",
            displayName: "Baichuan 4",
            vendor: "百川智能",
            inputPricePerMillion: 1.4,
            outputPricePerMillion: 1.4,
            cacheReadPricePerMillion: 0.14,
            defaultNote: "百川自研通用大模型"
        ),
        BuiltinModelPricing(
            modelName: "muse-spark-1.3-contributor",
            displayName: "Muse Spark 1.3 Contributor",
            vendor: "ClinePass",
            inputPricePerMillion: 0.1,
            outputPricePerMillion: 0.2,
            cacheReadPricePerMillion: 0.002,
            defaultNote: "社区贡献轻量模型"
        ),
        BuiltinModelPricing(
            modelName: "jev-latest",
            displayName: "Jev Latest",
            vendor: "TypeSafe",
            inputPricePerMillion: 0.042,
            outputPricePerMillion: 0.0,
            defaultNote: "极低成本高吞吐补全"
        ),
    ]
}
