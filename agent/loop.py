#!/usr/bin/env python3
"""
iosclaw 自主迭代 Agent
仿照 OpenClaw 模式：持续分析 → 改进 → Build验证 → Simulator测试 → Commit → 循环
实时流式输出每个工具调用和 Claude 的思考过程
"""

import anyio
import sys
from datetime import datetime

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    ResultMessage,
    SystemMessage,
    TextBlock,
    ToolResultBlock,
    ToolUseBlock,
    query,
)

PROJECT_DIR = "/Users/yaxinli/xym/iosagent"
SIM_ID = "6449AACA-25FA-4F2F-906D-C1564DDEF26E"   # iPhone 16 simulator UUID
BUNDLE_ID = "com.iosclaw.assistant"

SYSTEM_PROMPT = """你是一位有乔布斯式产品直觉的 iOS Swift 工程师，负责打磨 iosclaw——一款真正了解用户自己的私人 AI 助手。

## 产品核心理念
iosclaw 的价值在于：它是唯一能回答"我自己"问题的助手。
- "我上周运动了多少？" → HealthKit 真实数据
- "我最近去了哪些地方？" → CoreLocation 轨迹
- "帮我找那张在海边拍的照片" → Photos 智能搜索
- "我今天有什么日程？" → Calendar/EventKit
- "我上次记录的备忘是什么？" → CoreData LifeEvent

这不是一个工具箱。这是一面镜子，映射用户真实的生活数据。

## 项目架构
iosclaw 是一个 iOS 16+ AI 私人助手，采用 ClawSkill 插件架构：
- Bundle ID: com.iosclaw.assistant | App Group: group.com.iosclaw.assistant
- 技术栈: SwiftUI + CoreData + MVVM + HealthKit + CoreLocation + Speech
- **本地优先，网络兜底**：已知 intent 由本地 Skill 处理，unknown intent 通过 RawGPTService 调用远程 GPT 后端
- Skills 路径: PrivateAI/AI/Skills/
- Services 路径: PrivateAI/Services/
- Views 路径: PrivateAI/Views/

## 关键文件
- PrivateAI/AI/ClawSkill.swift — ClawSkill 协议定义
- PrivateAI/AI/SkillRouter.swift — NLP 关键词路由（含 QueryIntent enum）
- PrivateAI/AI/ClawEngine.swift — 核心引擎，注册所有 Skills
- PrivateAI/AI/ContextMemory.swift — 多轮对话上下文
- PrivateAI/Services/HealthService.swift — HealthKit 数据
- PrivateAI/Services/PhotoMetadataService.swift — 照片元数据
- PrivateAI/Services/PhotoSearchService.swift — 照片搜索
- PrivateAI/Services/LocationService.swift — 位置记录
- PrivateAI/Services/CalendarService.swift — 日历事件
- PrivateAI/ViewModels/ChatViewModel.swift — 聊天逻辑
- project.yml — xcodegen 配置（path: PrivateAI 自动包含所有 .swift 文件）

## 每次迭代流程（严格执行，不可跳步）

### Step 1: 了解现状
```bash
git log --oneline -15   # 避免重复已有改进
```

### Step 2: 分析问题
深入阅读相关 Skill/Service 代码，找到一个真实的质量问题。
**优先修复影响核心功能正确性的 bug，而不是添加新功能。**

### Step 3: 实现改进
完整实现代码改动。

### Step 4: 构建验证（必须执行）
```bash
cd /Users/yaxinli/xym/iosagent && xcodegen generate && \
xcodebuild build \
  -project iosclaw.xcodeproj \
  -scheme iosclaw \
  -destination 'id=6449AACA-25FA-4F2F-906D-C1564DDEF26E' \
  -configuration Debug \
  ONLY_ACTIVE_ARCH=YES 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```
- 如果出现 Swift 编译错误（`error: ...`），**必须修复后重新构建，直到 BUILD SUCCEEDED**
- `appintentsnltrainingprocessor error` 不是 Swift 错误，可以忽略

### Step 5: Simulator 安装测试（必须执行）
```bash
# 安装到 simulator
xcrun simctl install 6449AACA-25FA-4F2F-906D-C1564DDEF26E \
  $(find ~/Library/Developer/Xcode/DerivedData/iosclaw-*/Build/Products/Debug-iphonesimulator -name "iosclaw.app" | head -1)

# 启动 app（确认能正常运行）
xcrun simctl launch 6449AACA-25FA-4F2F-906D-C1564DDEF26E com.iosclaw.assistant

# 抓取 5 秒启动日志（确认无 crash）
sleep 2 && log show --predicate 'process == "iosclaw"' --last 10s --style compact 2>/dev/null | grep -v "^Timestamp" | head -20
```

### Step 6: 提交
```bash
git add -A && git commit -m "fix/improve/feat: 英文简洁描述"
```

## 当前已知问题（优先修复）

### 🔴 严重：simulator 中功能异常
根本原因分析：
1. **HealthKit 在 simulator 中无真实数据** → HealthSkill/SummarySkill 返回空结果，需要给出合理提示
2. **SkillRouter 路由不准** → 常见查询可能被路由到错误的 intent 或 .unknown
3. **过度复杂的 SummarySkill** — 3500+ 行，很多分支假设有大量数据
4. **非 iOS 原生功能 Skill 堆积** — ClawEngine 注册了 30+ Skills，大量是无关功能

### 具体修复建议
- **首要**：检查 SkillRouter 是否能正确识别基础查询如"今天步数"、"最近日程"、"帮我找照片"
- **其次**：验证 CalendarSkill/HealthSkill 在无数据时是否给出合理提示（而不是空白或崩溃）
- **再次**：确认 UnknownSkill 的回复是否合理（路由失败时的本地 fallback）
- **最后**：考虑移除或禁用非 iOS 原生数据相关的冗余 Skills

## 改进优先级（按重要性排序）

### 🥇 最高优先：修复核心功能正确性
1. 修复无数据/无权限时的边界情况 → 给出有意义的提示
2. 修复 SkillRouter 路由缺失 → 减少落到 unknown 的情况
3. 修复 simulator 中可复现的 bug
4. 如有必要，清理非核心 Skills（但要谨慎，避免破坏已有功能）

### 🥈 次优先：深化 iOS 原生数据能力
- **HealthSkill**：更丰富的健康数据解读（睡眠分析、心率趋势、运动类型细分）
- **CalendarSkill**：更自然的日程查询，支持"本周"、"明天"、"下周一"
- **LocationSkill**：总结用户去过的地方，识别常去场所
- **SummarySkill**：真正有洞察力的个人数据总结

### 🥉 最低优先：仅在有明确价值时才新增 Skill
新增 Skill 的标准：必须依赖 iOS 原生数据（HealthKit/Photos/Location/Calendar/CoreData），
纯本地计算类功能（番茄钟、记账、密码生成、BMI、单位换算等）不符合产品定位，不要新增。

## 硬性约束
- 不修改 .xcdatamodeld CoreData 模型文件
- 使用 Swift 5.9 兼容语法，支持 iOS 16+
- 每次只做一个聚焦的改进，不大规模重构
- 提交信息必须是英文，简洁描述实际改动
- **每次改动后必须 BUILD SUCCEEDED 才能提交**
- 不新增与 iOS 原生数据无关的独立功能 Skill
- **绝对不要删除或修改 RawGPTService.swift** — 它是 unknown intent 的网络兜底服务，架构正确
- **绝对不要修改 ChatViewModel 中调用 RawGPTService 的逻辑** — 本地 Skill 优先、网络兜底是正确的设计
"""

ITERATION_PROMPT = """分析 iosclaw iOS 项目（路径: /Users/yaxinli/xym/iosagent）。

先运行 git log --oneline -15 查看最近改动，再深入阅读相关代码。

**本次重点**：
iosclaw 是一款 iOS 私人助手（本地 Skill 优先，RawGPTService 网络兜底），
核心价值是帮用户查询自己的 iOS 数据（健康/照片/位置/日历）。

找到一个影响核心功能正确性的问题，完整修复它，然后：
1. 运行 xcodebuild 验证编译通过（BUILD SUCCEEDED）
2. 安装到 simulator 并确认能启动
3. 提交

**注意**：不要删除或修改 RawGPTService.swift 和 ChatViewModel 中的网络兜底逻辑。
优先修复 bug，而不是添加新功能。"""


def fmt_tool(block: ToolUseBlock) -> str:
    """格式化工具调用为单行日志"""
    name = block.name
    inp = block.input or {}
    if name == "Bash":
        cmd = str(inp.get("command", "")).strip().replace("\n", " ")[:90]
        return f"🔧 Bash  │ {cmd}"
    elif name == "Read":
        return f"📖 Read  │ {inp.get('file_path', '')}"
    elif name == "Edit":
        return f"✏️  Edit  │ {inp.get('file_path', '')}"
    elif name == "Write":
        return f"📝 Write │ {inp.get('file_path', '')}"
    elif name == "Glob":
        return f"🔍 Glob  │ {inp.get('pattern', '')}"
    elif name == "Grep":
        return f"🔍 Grep  │ {inp.get('pattern', '')}"
    return f"🛠  {name}"


async def run_iteration(iteration: int, total_cost_so_far: float = 0.0) -> float:
    timestamp = datetime.now().strftime("%H:%M:%S")
    print(f"\n{'─' * 62}")
    print(f"  [{timestamp}] 迭代 #{iteration}  [累计: ${total_cost_so_far:.4f}]")
    print(f"{'─' * 62}", flush=True)

    options = ClaudeAgentOptions(
        cwd=PROJECT_DIR,
        allowed_tools=["Read", "Write", "Edit", "Bash", "Glob", "Grep"],
        permission_mode="bypassPermissions",
        system_prompt=SYSTEM_PROMPT,
        max_turns=60,
        model="claude-opus-4-6",
    )

    try:
        async with ClaudeSDKClient(options=options) as client:
            await client.query(ITERATION_PROMPT)

            async for message in client.receive_response():
                if isinstance(message, SystemMessage) and message.subtype == "init":
                    sid = message.data.get("session_id", "")[:8]
                    print(f"  Session: {sid}…", flush=True)

                elif isinstance(message, AssistantMessage):
                    for block in message.content:
                        if isinstance(block, TextBlock) and block.text.strip():
                            text = block.text.strip().replace("\n", " ")
                            print(f"  💭 {text[:120]}", flush=True)
                        elif isinstance(block, ToolUseBlock):
                            print(f"  {fmt_tool(block)}", flush=True)

                elif isinstance(message, ResultMessage):
                    cost = message.total_cost_usd or 0.0
                    turns = message.num_turns
                    usage = message.usage or {}
                    inp = usage.get("input_tokens", 0)
                    out = usage.get("output_tokens", 0)
                    preview = (message.result or "").strip()[:180]
                    print(f"\n  ✓ 完成  💰 ${cost:.4f}  🔄 {turns}轮  📊 {inp:,}in/{out:,}out tokens", flush=True)
                    print(f"  {preview}", flush=True)
                    return cost

    except KeyboardInterrupt:
        raise
    except Exception as e:
        print(f"\n  ✗ 出错: {type(e).__name__}: {e}", flush=True)
        return 0.0

    return 0.0


async def main():
    interval = 10
    if len(sys.argv) > 1:
        try:
            interval = int(sys.argv[1])
        except ValueError:
            pass

    print("🦞 iosclaw 自主迭代 Agent  (Ctrl+C 停止)")
    print(f"   项目: {PROJECT_DIR}")
    print(f"   Simulator: iPhone 16 ({SIM_ID[:8]}…)")
    print(f"   间隔: {interval}s  │  模型: claude-opus-4-6\n")

    iteration = 1
    total_cost = 0.0

    while True:
        try:
            cost = await run_iteration(iteration, total_cost)
            total_cost += cost
        except KeyboardInterrupt:
            print(f"\n\n👋 已停止，共完成 {iteration - 1} 次迭代，累计花费 ${total_cost:.4f}")
            sys.exit(0)
        except Exception as e:
            print(f"  未处理错误: {e}", flush=True)

        iteration += 1
        print(f"\n  ⏳ {interval}s 后开始迭代 #{iteration}…  [累计: ${total_cost:.4f}]", flush=True)

        try:
            await anyio.sleep(interval)
        except KeyboardInterrupt:
            print(f"\n\n👋 已停止，共完成 {iteration - 1} 次迭代，累计花费 ${total_cost:.4f}")
            sys.exit(0)


if __name__ == "__main__":
    anyio.run(main)
