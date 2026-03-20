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
iosclaw 是一个 iOS 16+ AI 私人助手，采用 GPT-first 架构：
- Bundle ID: com.iosclaw.assistant | App Group: group.com.iosclaw.assistant
- 技术栈: SwiftUI + CoreData + MVVM + HealthKit + CoreLocation + Speech
- **GPT-first**：所有用户查询 → GPTContextBuilder 收集本地数据 → RawGPTService（Azure GPT 后端）→ 回复
- 本地 Services 提供数据，GPT 决定如何回答，无本地关键词路由
- Services 路径: PrivateAI/Services/
- Views 路径: PrivateAI/Views/

## 关键文件
- PrivateAI/AI/GPTContextBuilder.swift — 核心：收集所有本地数据，组装结构化 prompt
- PrivateAI/Services/RawGPTService.swift — 远程 GPT 后端调用（Azure，POST /api/rawGPT）
- PrivateAI/Services/HealthService.swift — HealthKit 数据（步数/睡眠/心率/运动等）
- PrivateAI/Services/PhotoMetadataService.swift — 照片元数据
- PrivateAI/Services/PhotoSearchService.swift — 照片搜索（本地 Vision 索引）
- PrivateAI/Services/LocationService.swift — 位置记录
- PrivateAI/Services/CalendarService.swift — 日历事件
- PrivateAI/ViewModels/ChatViewModel.swift — 聊天逻辑（单路径 GPT）
- project.yml — xcodegen 配置（path: PrivateAI 自动包含所有 .swift 文件）

## 每次迭代流程（严格执行，不可跳步）

### Step 1: 了解现状
```bash
git log --oneline -15   # 避免重复已有改进
```

### Step 2: 分析问题
深入阅读 GPTContextBuilder.swift、Services、ChatViewModel，找到一个真实的质量问题。
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
xcrun simctl install 6449AACA-25FA-4F2F-906D-C1564DDEF26E \
  $(find ~/Library/Developer/Xcode/DerivedData/iosclaw-*/Build/Products/Debug-iphonesimulator -name "iosclaw.app" | head -1)
xcrun simctl launch 6449AACA-25FA-4F2F-906D-C1564DDEF26E com.iosclaw.assistant
```

### Step 6: 提交（commit message 必须英文）
```bash
git add -A && git commit -m "fix/improve: brief English description

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>"
```

## 改进优先级（按重要性排序）

### 🥇 最高优先：GPT prompt 质量
1. 改进 GPTContextBuilder 的 prompt 结构，让 GPT 回答更精准
2. 改进 Services 的数据获取（边界情况、无权限时给提示）
3. 改进 RawGPTService 的错误处理（超时、解析失败等）
4. 改进 PhotoSearchService 的搜索质量

### 🥈 次优先：Services 数据深度
- HealthService：确保 7 天趋势数据准确，睡眠阶段完整
- CalendarService：确保时区处理正确，全天事件显示正确
- LocationService：确保地点名称准确（reverse geocoding）
- PhotoSearchService：确保关键词 → 标签映射覆盖更多场景

### 🥉 最低优先：UI 体验
- ChatViewModel / ChatView 的小优化
- 错误提示文案优化

## 硬性约束
- 不修改 .xcdatamodeld CoreData 模型文件
- 使用 Swift 5.9 兼容语法，支持 iOS 16+
- 每次只做一个聚焦的改进，不大规模重构
- **每次改动后必须 BUILD SUCCEEDED 才能提交**
- **绝对不要删除或修改 RawGPTService.swift**
- **绝对不要修改 ChatViewModel 中的 sendMessage() 核心流程**
- **不要新增 Skill 文件或恢复旧的 SkillRouter 架构** — 已迁移到 GPT-first，不可回退
"""

ITERATION_PROMPT = """分析 iosclaw iOS 项目（路径: /Users/yaxinli/xym/iosagent）。

先运行 git log --oneline -15 查看最近改动，再深入阅读相关代码。

**架构说明（必须了解）**：
iosclaw 现在是 GPT-first 架构：
- 所有用户查询 → GPTContextBuilder.buildPrompt() → RawGPTService.shared.ask() → 显示回复
- GPTContextBuilder 收集所有本地数据（健康/日历/位置/照片/生活记录）组装成结构化 prompt
- 没有本地 SkillRouter，没有 ClawSkill，没有 SkillRegistry
- 核心文件：PrivateAI/AI/GPTContextBuilder.swift，PrivateAI/Services/RawGPTService.swift

找到一个能提升产品质量的改进点（优先改进 prompt 质量、数据准确性、错误处理），完整实现后：
1. xcodebuild 验证 BUILD SUCCEEDED
2. 安装到 simulator 确认启动正常
3. 提交"""


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
