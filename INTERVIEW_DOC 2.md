# PrivateAI — 项目面试文档 / Project Interview Documentation

> **定位 / Positioning**: 本地隐私优先的 AI 个人助理 iOS App，零网络依赖，全量数据存储于设备端。
> A local privacy-first AI personal assistant iOS app with zero network dependency and all data stored on-device.

---

## 目录 / Table of Contents

1. [项目概览 / Project Overview](#1-项目概览--project-overview)
2. [架构设计 / Architecture Design](#2-架构设计--architecture-design)
3. [目录结构 / Directory Structure](#3-目录结构--directory-structure)
4. [核心模块详解 / Core Modules](#4-核心模块详解--core-modules)
5. [数据流 / Data Flow](#5-数据流--data-flow)
6. [CoreData 数据模型 / CoreData Model](#6-coredata-数据模型--coredata-model)
7. [AI 引擎 / AI Engine](#7-ai-引擎--ai-engine)
8. [iOS 系统集成 / iOS System Integration](#8-ios-系统集成--ios-system-integration)
9. [性能与安全 / Performance & Security](#9-性能与安全--performance--security)
10. [面试高频问题 / Interview Q&A](#10-面试高频问题--interview-qa)

---

## 1. 项目概览 / Project Overview

### 中文描述

PrivateAI 是一款完全离线的 iOS 私人 AI 助理，用户可以用自然语言（中英文）询问自己的生活数据——运动步数、睡眠、心情日记、去过的地点、日历日程、照片记录等。所有 AI 推断和数据存储均在设备本地完成，无任何数据上报服务器。

### English Description

PrivateAI is a fully offline iOS personal AI assistant. Users can ask natural language questions (Chinese/English) about their own life data—exercise steps, sleep, mood journal, visited locations, calendar events, photo metadata, and more. All AI inference and data storage happens on-device with no data sent to any server.

### 技术栈 / Tech Stack

| 层次 Layer | 技术 Technology |
|---|---|
| UI 框架 | SwiftUI (iOS 16+) |
| 状态管理 State Management | Combine + @Published + @EnvironmentObject |
| 持久化 Persistence | CoreData (SQLite backend) |
| 健康数据 Health | HealthKit |
| 位置 Location | CoreLocation (Significant-change mode) |
| 日历 Calendar | EventKit |
| 照片 Photos | PhotosKit (metadata only) |
| 语音输入 Speech | Speech framework (on-device) |
| 通知 Notifications | UserNotifications |
| 图表 Charts | Swift Charts (iOS 16+) |
| 架构模式 Pattern | MVVM + Service Layer |
| 构建配置 Build Config | XcodeGen (project.yml) |

---

## 2. 架构设计 / Architecture Design

### 整体架构图 / Architecture Diagram

```
┌─────────────────────────────────────────────────────┐
│                    SwiftUI Views                    │
│  ChatView  TimelineView  StatsView  ProfileView     │
└──────────────────┬──────────────────────────────────┘
                   │ @ObservedObject / @EnvironmentObject
┌──────────────────▼──────────────────────────────────┐
│                  ViewModels (MVVM)                  │
│  ChatViewModel  TimelineVM  StatsVM  ProfileVM      │
└──────────────────┬──────────────────────────────────┘
                   │ function calls
┌──────────────────▼──────────────────────────────────┐
│               AppState (中枢状态 / Hub State)        │
│         EnvironmentObject — holds all services      │
└──────┬────────────────────────────────┬─────────────┘
       │                                │
┌──────▼──────────┐          ┌──────────▼──────────────┐
│  AI Layer       │          │   Service Layer          │
│  IntentParser   │          │  LocationService         │
│  LocalAIEngine  │          │  HealthService           │
│  ContextMemory  │          │  CalendarService         │
└──────┬──────────┘          │  PhotoMetadataService    │
       │                     │  NotificationService     │
┌──────▼──────────┐          │  SpeechService           │
│  CoreData       │          └──────────────────────────┘
│  PersistenceCtrl│
│  CDChatMessage  │
│  CDLifeEvent    │
│  CDLocationRecord│
│  CDUserProfile  │
└─────────────────┘
```

### MVVM 职责边界 / MVVM Responsibility Boundaries

| 层次 | 职责 | 禁止做的事 |
|------|------|-----------|
| **View** | 渲染 UI，绑定 ViewModel | 直接访问 CoreData 或 Services |
| **ViewModel** | 处理业务逻辑，驱动 UI 更新 | 直接操作 CoreData（通过 Engine/Service 间接访问）|
| **Service** | 封装系统 API（HK/CL/EK）| 修改 UI 状态 |
| **AI Layer** | 解析意图，生成回复 | 直接持有 ViewModel 引用 |
| **AppState** | 持有所有 Services，管理权限 | 包含业务逻辑 |

---

## 3. 目录结构 / Directory Structure

```
PrivateAI/
├── App/
│   └── PrivateAIApp.swift          # @main 入口，初始化 CoreData + AppState
│
├── Persistence/
│   ├── PersistenceController.swift  # CoreData 栈，单例模式
│   └── PrivateAI.xcdatamodeld/     # 4 个 Entity 定义
│
├── Models/
│   ├── AppModels.swift             # Swift 值类型：ChatMessage, LifeEvent, etc.
│   └── CoreDataExtensions.swift    # CD Entity <-> Swift Model 双向转换
│
├── Services/
│   ├── LocationService.swift       # CLLocationManager 封装
│   ├── HealthService.swift         # HealthKit 封装
│   ├── CalendarService.swift       # EventKit 封装（iOS 16/17 兼容）
│   ├── PhotoMetadataService.swift  # Photos 框架（只读元数据）
│   ├── NotificationService.swift   # 本地推送（每日 + 每周）
│   ├── SpeechService.swift         # 设备端语音识别
│   └── RawGPTService.swift         # 可选远程 GPT 增强（fallback）
│
├── AI/
│   ├── IntentParser.swift          # 关键词 NLP，解析意图 + 时间范围
│   ├── LocalAIEngine.swift         # 查询数据 + 生成自然语言回复
│   └── ContextMemory.swift         # 多轮对话上下文（12 条缓冲）
│
├── ViewModels/
│   ├── AppState.swift              # EnvironmentObject 中枢，持有所有 Services
│   ├── ChatViewModel.swift         # 对话消息管理 + 意图解析调度
│   ├── TimelineViewModel.swift     # 事件过滤、搜索、增删
│   ├── StatsViewModel.swift        # 统计数据聚合，驱动图表
│   ├── ProfileViewModel.swift      # 用户档案加载/保存
│   └── SettingsViewModel.swift     # 数据导出/导入/清除
│
├── Views/
│   ├── ContentView.swift           # 路由：Onboarding → MainTabView
│   ├── MainTabView.swift           # 5 标签导航（助理/时光轴/统计/我/设置）
│   ├── Chat/
│   │   ├── ChatView.swift          # 对话界面，语音输入，推荐问题
│   │   └── MessageBubble.swift     # 消息气泡组件
│   ├── Timeline/TimelineView.swift # 事件时间轴 + 筛选器
│   ├── Stats/StatsView.swift       # Swift Charts 可视化
│   ├── Profile/ProfileView.swift   # 个人档案编辑
│   ├── Settings/SettingsView.swift # 权限开关 + 数据管理
│   ├── Map/                        # 地图视图（扩展）
│   └── QuickRecord/               # 快速记录（扩展）
│
├── Intents/                        # App Intents（快捷指令集成）
├── Widgets/                        # WidgetKit 小组件
│
└── Resources/
    ├── Info.plist                  # 隐私权限描述字符串
    ├── PrivateAI.entitlements      # HealthKit + App Groups 授权
    └── Assets.xcassets/           # AccentPrimary (#196AEA), AccentSecondary (#211FA1)
```

---

## 4. 核心模块详解 / Core Modules

### 4.1 AppState — 中枢状态管理

```swift
// AppState 是全局 EnvironmentObject，注入到整个 View 树
class AppState: ObservableObject {
    let locationService: LocationService
    let healthService: HealthService
    let calendarService: CalendarService
    let photoService: PhotoMetadataService
    let notificationService: NotificationService

    // 权限开关，持久化到 UserDefaults
    @AppStorage("locationEnabled") var locationEnabled = false
    @AppStorage("healthEnabled") var healthEnabled = false
    @AppStorage("calendarEnabled") var calendarEnabled = false
    @AppStorage("notificationsEnabled") var notificationsEnabled = false
}
```

**面试要点**: 为什么用 `@AppStorage` 而不是 `@Published`？因为权限开关需要在 App 重启后保持，@AppStorage 自动绑定到 UserDefaults。

### 4.2 ContextMemory — 多轮对话上下文

```swift
// 解决问题：用户问 "那昨天呢？" —— AI 需要知道上文说的是什么
class ContextMemory {
    private var recentMessages: [ContextMessage] = []  // 最多 12 条
    private(set) var lastIntent: ParsedIntent?
    private(set) var mentionedEntities: Set<String> = []

    // 关键方法：检测 follow-up 并继承上文意图
    func resolveIntent(from raw: String) -> ParsedIntent? {
        let followUpKeywords = ["那", "昨天", "上周", "呢", "then", "yesterday"]
        if followUpKeywords.contains(where: raw.contains),
           let last = lastIntent {
            // 继承上文意图，仅更新时间范围
            return last.withUpdatedTimeRange(from: raw)
        }
        return nil  // nil 表示需要 IntentParser 重新解析
    }
}
```

### 4.3 IntentParser — 关键词 NLP

**11 种意图类型 / 11 Intent Types:**

| 意图 Intent | 触发关键词 (示例) | 说明 |
|-------------|-----------------|------|
| `.exercise(range)` | 运动, 锻炼, workout | 查询运动记录 |
| `.location(range)` | 去过, 位置, where | 查询位置历史 |
| `.mood(range)` | 心情, 情绪, mood | 查询心情分析 |
| `.health(metric, range)` | 步数, 睡眠, 心率, steps | 查询健康数据 |
| `.calendar(range)` | 日程, 会议, schedule | 查询日历事件 |
| `.photos(range)` | 照片, 拍了, photo | 查询照片统计 |
| `.summary(range)` | 总结, 回顾, summary | 综合数据摘要 |
| `.recommendation(topic)` | 推荐, 礼物, gift | AI 推荐 |
| `.streak` | 打卡, 连续, streak | 连续达标天数 |
| `.weeklyInsight` | 本周, 这周, this week | 周度洞察 |
| `.comparison` | 对比, 变化, compare | 本周 vs 上周 |

**时间范围解析 / Time Range Parsing:**

```swift
enum QueryTimeRange {
    case today, yesterday, thisWeek, lastWeek, thisMonth, custom(Date, Date)
}
// 关键词映射："今天"→.today  "昨天"→.yesterday  "本周"→.thisWeek
```

### 4.4 LocalAIEngine — 本地推理引擎

```swift
// 核心方法：根据意图查询数据并生成自然语言回复
func respond(to intent: ParsedIntent, context: ContextMemory) async -> String {
    switch intent {
    case .exercise(let range):
        let events = CDLifeEvent.fetch(from: range, category: .exercise, in: context)
        let health = await healthService.fetchDailySummary(for: range.midDate)
        return generateExerciseResponse(events: events, health: health)

    case .mood(let range):
        let events = CDLifeEvent.fetch(from: range, in: context)
        let moodMap = Dictionary(grouping: events, by: \.mood)
        return generateMoodAnalysis(moodMap: moodMap)

    // ... 20+ 种 case handlers
    }
}
```

**回复生成策略 / Response Generation Strategy:**
1. **规则模板（主）**: 格式化数据 + emoji，始终可用
2. **远程 GPT（可选）**: 网络可用时发送上下文到 Azure 端点，获取更自然的叙述
3. **优雅降级**: 无权限 → 提示用户开启；无数据 → 友好提示

---

## 5. 数据流 / Data Flow

### 5.1 用户发送消息 / User Sends Message

```
用户输入 (ChatView)
    │
    ▼
ChatViewModel.sendMessage(text)
    │
    ├─ ContextMemory.add(userMessage)
    ├─ ContextMemory.resolveIntent(text)   ← 检查是否 follow-up
    │
    ▼
IntentParser.parse(text)                  ← 如果不是 follow-up
    │
    ▼
LocalAIEngine.respond(intent)
    │
    ├─ CDLifeEvent.fetch(range)            ← CoreData 查询
    ├─ HealthService.fetchSummary()        ← HealthKit 查询
    ├─ CalendarService.fetchEvents()       ← EventKit 查询
    └─ PhotoMetadataService.fetchStats()   ← Photos 查询
    │
    ▼
生成自然语言回复
    │
    ▼
CDChatMessage.create() + PersistenceController.save()
ContextMemory.add(aiMessage)
    │
    ▼
@Published var messages 更新 → UI 自动刷新
```

### 5.2 位置数据后台采集 / Background Location Collection

```
CLLocationManager (后台显著变化监控)
    │
    ▼ 位置更新（每次移动 > 200m 且间隔 > 5min）
    │
LocationService.locationManager(_:didUpdateLocations:)
    │
    ├─ 距离检查 (distance > 200m)
    ├─ 时间检查 (time > 300s)
    │
    ▼
CLGeocoder.reverseGeocodeLocation()      ← 异步反地理编码
    │
    ▼
newBackgroundContext().perform {         ← 后台 CoreData 上下文
    CDLocationRecord.create(...)
    context.save()
}
```

### 5.3 语音输入 / Voice Input

```
用户点击麦克风 → SpeechService.startListening()
    │
AVAudioEngine + SFSpeechRecognitionTask (requiresOnDeviceRecognition = true)
    │
    ▼ 实时转录（partial results）
SpeechService.$transcript (Combine @Published)
    │
ChatViewModel 订阅 → inputText 实时更新
    │
用户停止 → 作为普通文本消息发送
```

---

## 6. CoreData 数据模型 / CoreData Model

### 4 个实体 / 4 Entities

#### CDChatMessage
```
id: UUID
content: String          // 消息内容
isUser: Boolean          // true=用户, false=AI
timestamp: Date
```

#### CDLifeEvent
```
id: UUID
title: String            // 事件标题
content: String          // 详细内容
mood: String             // MoodType 枚举原始值 (happy/calm/sad/angry/anxious/neutral)
category: String         // EventCategory 枚举 (exercise/food/social/work/health/travel/other)
tags: String             // 逗号分隔标签
timestamp: Date
```

#### CDLocationRecord
```
id: UUID
latitude: Double
longitude: Double
altitude: Double
address: String          // 完整地址
placeName: String        // 简短地名（反地理编码结果）
duration: Double         // 停留时长（分钟）
timestamp: Date
```

#### CDUserProfile
```
id: UUID
name: String
birthday: Date
occupation: String
notes: String
aiStyle: String          // AI 回复风格偏好
interests: String        // JSON 数组 ["健身", "阅读", ...]
familyInfo: String       // JSON 数组 [{name, relation, birthday}, ...]
lastUpdated: Date
```

### 关键设计决策 / Key Design Decisions

| 决策 | 原因 |
|------|------|
| interests 和 familyInfo 存为 JSON 字符串 | 避免关系表的复杂度，数据量小，不需要独立查询 |
| 枚举值存为 String rawValue | CoreData 不支持枚举类型，String 可读性好 |
| 使用 `codeGenerationType="class"` | Xcode 自动生成 NSManagedObject 子类，减少样板代码 |
| PersistenceController 单例 | 确保全局唯一的 CoreData 栈，防止多实例竞争 |

---

## 7. AI 引擎 / AI Engine

### 为什么不用 ML 模型？ / Why Rule-Based Instead of ML?

| 考量 | 规则引擎 Rule-Based | CoreML 模型 |
|------|---------------------|-------------|
| 隐私 Privacy | 完全透明，可审计 | 需要训练数据，模型可能泄露信息 |
| 速度 Speed | 毫秒级 | 需要模型加载时间 |
| 可定制 Customizable | 直接修改关键词 | 需要重新训练 |
| 准确率 Accuracy | 对常见模式准确 | 更好的泛化能力 |
| 包大小 Bundle Size | 无额外资源 | 模型文件 10MB+ |

**结论**: 对于这个场景（有限的意图类型，主要是中文关键词匹配），规则引擎是更合理的选择。

### 连续性对话实现 / Multi-Turn Conversation

```swift
// 问题：用户说 "那昨天呢？"，AI 怎么知道"那"指的是运动？

// 解决方案：ContextMemory 记录最近 12 条消息 + 最后的意图
// 1. 检测 follow-up 关键词（那、昨天、呢、then...）
// 2. 如果是 follow-up，继承 lastIntent，只更新时间范围
// 3. 如果不是，交给 IntentParser 全量解析

// 示例对话
用户: "我今天运动了多少？"          → intent: .exercise(.today)
AI:   "今天走了 8,234 步..."
用户: "那昨天呢？"                  → 检测到 follow-up → intent: .exercise(.yesterday)
AI:   "昨天走了 6,100 步..."
```

### 推荐礼物功能 / Gift Recommendation

```swift
// 结合用户档案中的家人信息进行个性化推荐
case .recommendation(let topic):
    let profile = CDUserProfile.fetchOrCreate(in: context)
    let familyMembers = profile.parsedFamilyInfo  // JSON 解析
    let targetPerson = familyMembers.first { topic.contains($0.relation) }
    // 根据关系和生日生成个性化推荐
```

---

## 8. iOS 系统集成 / iOS System Integration

### HealthKit 集成

```swift
// 并发查询 6 个健康指标
func fetchDailySummary(for date: Date) async -> HealthSummary {
    return await withCheckedContinuation { continuation in
        let group = DispatchGroup()
        var steps = 0.0, calories = 0.0, exercise = 0.0, heartRate = 0.0, sleep = 0.0

        group.enter(); querySteps(date) { steps = $0; group.leave() }
        group.enter(); queryCalories(date) { calories = $0; group.leave() }
        group.enter(); queryExercise(date) { exercise = $0; group.leave() }
        group.enter(); queryHeartRate(date) { heartRate = $0; group.leave() }
        group.enter(); querySleep(date) { sleep = $0; group.leave() }

        group.notify(queue: .main) {
            continuation.resume(returning: HealthSummary(steps: steps, ...))
        }
    }
}
```

### EventKit iOS 16/17 兼容性 / EventKit iOS 16/17 Compatibility

```swift
func requestAccess() async -> Bool {
    if #available(iOS 17.0, *) {
        // iOS 17 新 API：精确到日历级别的权限
        return (try? await eventStore.requestFullAccessToEvents()) ?? false
    } else {
        // iOS 16 旧 API
        return await withCheckedContinuation { continuation in
            eventStore.requestAccess(to: .event) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }
}
```

### 位置追踪策略 / Location Tracking Strategy

| 策略 | 特点 | 本项目选择原因 |
|------|------|--------------|
| Standard Location Updates | 高精度，高耗电 | 不适合常驻后台 |
| **Significant-Change Mode** | 精度较低，极低耗电 | 记录生活轨迹不需要高精度 |
| Region Monitoring | 固定围栏触发 | 不适合动态追踪 |
| Visit Monitoring | 自动检测停留 | 可作为未来升级方案 |

### Widget 数据同步 / Widget Data Sync

```swift
// App Group 共享 UserDefaults 实现 Widget 读取 App 数据
let sharedDefaults = UserDefaults(suiteName: "group.com.privateai.assistant")
sharedDefaults?.set(todaySteps, forKey: "widget_steps")
sharedDefaults?.set(todayMood, forKey: "widget_mood")
// Widget 在 TimelineProvider 中读取同一个 suiteName
```

---

## 9. 性能与安全 / Performance & Security

### 性能优化 / Performance Optimizations

| 技术 | 应用场景 | 效果 |
|------|---------|------|
| **后台 CoreData Context** | LocationService 存储位置 | 不阻塞主线程 |
| **DispatchGroup 并发** | HealthKit 6 项指标查询 | 并行查询，减少总时间 |
| **Debounce 防抖** | 位置存储（300s 最短间隔） | 避免频繁写入 |
| **ContextMemory 滑动窗口** | 对话上下文保留 12 条 | 避免内存无限增长 |
| **按需加载** | Stats/Timeline 切换 Range 时才查询 | 减少不必要的 CoreData 查询 |

### 隐私保护 / Privacy Protection

```
数据存储 ✓ 全部在本地 (CoreData SQLite)
语音识别 ✓ requiresOnDeviceRecognition = true（禁止上传服务器）
照片访问 ✓ 只读元数据（日期/位置/收藏标志），从不读取图片内容
健康数据 ✓ 只读，从不写入，从不上传
网络请求 ✓ 默认无网络；RawGPT 为可选增强，用户可关闭
```

### 错误处理策略 / Error Handling Strategy

| 场景 | 处理方式 |
|------|---------|
| 无网络 | 静默降级到本地 AI，不显示错误 |
| HealthKit 未授权 | 返回空 HealthSummary，AI 提示开启权限 |
| 语音识别失败 | 自动停止监听，用户可重试 |
| CoreData 初始化失败 | fatalError（快速失败，开发期暴露问题）|
| 权限被拒绝 | AI 回复中建议开启对应权限 |

---

## 10. 面试高频问题 / Interview Q&A

### Q1: 为什么选择 MVVM 而不是 MVC 或其他模式？
**Answer**: iOS 开发中 MVC 容易形成 "Massive View Controller"。MVVM 配合 Combine 的 `@Published` 可以将业务逻辑从 View 中分离，使 ViewModel 可以独立单元测试，而无需 UI 环境。本项目中每个 ViewModel 职责清晰，ChatViewModel 只管对话，StatsViewModel 只管数据聚合。

### Q2: ContextMemory 的 12 条限制是怎么考虑的？
**Answer**: 这是内存与上下文深度的权衡。12 条约等于 6 轮对话，覆盖绝大多数连续追问场景（"那上周呢？" "那上上周呢？"）。超过 12 条后，最老的消息被丢弃，这是 LRU 思路。如果需要更长上下文，可以配合 CoreData 做持久化上下文，但会增加复杂度。

### Q3: CoreData 的 Background Context 为什么重要？
**Answer**: CoreData 的 `viewContext` 绑定到主线程（Main Queue Concurrency）。如果在主线程进行大量 I/O 操作（如位置持续写入），会导致 UI 卡顿。`newBackgroundContext()` 创建私有队列 Context，配合 `.perform {}` 在后台线程执行 CoreData 操作，主线程只负责渲染。

### Q4: 为什么用 DispatchGroup 而不是 async/await 并发查询？
**Answer**: HealthKit 的 `HKStatisticsQuery` 是基于闭包回调的旧式 API，没有原生 async/await 版本。DispatchGroup 是处理多个闭包回调并等待全部完成的标准方案。将其包装在 `withCheckedContinuation` 中，可以对外暴露 async 接口，让调用方使用 await 语法，兼顾了旧 API 和现代 async/await。

### Q5: 如何处理 EventKit 的 iOS 版本差异？
**Answer**: iOS 17 引入了 `requestFullAccessToEvents()`（更精细的权限粒度），而 iOS 16 只有 `requestAccess(to:)`。通过 `#available(iOS 17.0, *)` 条件编译，在运行时选择合适的 API，确保在两个系统版本上都能正常工作，同时利用新版本更好的权限模型。

### Q6: Keyword-based NLP 相比机器学习模型的优缺点？
**优点**: 完全透明可审计、无需训练数据、无模型文件体积、毫秒级响应、易于针对特定领域定制（中文关键词）。
**缺点**: 无法处理未见过的表达方式、同义词覆盖不完整、无法理解语义关系（如"跑步"和"慢跑"需要各自配置）。
**改进方向**: 可以引入 CoreML + 轻量级 NLModel（苹果的 Create ML 训练）作为补充，保持隐私的同时提升泛化能力。

### Q7: 为什么用 @AppStorage 而不是 @State + UserDefaults？
**Answer**: `@AppStorage` 是 `@State` 的 UserDefaults 绑定版本，数据自动持久化并在多个视图间同步。如果用 `@State` 需要手动读写 UserDefaults，且不同视图间需要通过 `@EnvironmentObject` 传递。`@AppStorage` 更简洁，适合简单的偏好设置，缺点是不适合存储复杂对象（应使用 Codable + UserDefaults/CoreData）。

### Q8: 如果要支持 iCloud 同步，需要做哪些改动？
**Answer**:
1. 将 `PersistenceController` 的 `NSPersistentContainer` 改为 `NSPersistentCloudKitContainer`
2. 处理 CoreData + CloudKit 的合并策略（`NSMergeByPropertyObjectTrumpMergePolicy`）
3. 处理 CloudKit 同步冲突（last-write-wins 或 custom resolver）
4. 注意 HealthKit/Calendar 数据不能存储在 iCloud（隐私限制）
5. App Group 中的 Widget 数据也需要通过 CloudKit 同步

### Q9: App 如何在后台持续采集位置而不被系统杀掉？
**Answer**: 使用 Significant-Change Location 模式（`startMonitoringSignificantLocationChanges()`），这是苹果官方的后台位置服务之一。系统会在用户移动超过约 500m 时唤醒 App，不需要持续运行后台任务。相比 Standard Updates，系统更不容易终止此类 App。同时在 `Info.plist` 中声明 `location` Background Mode，在 Entitlements 中配置 HealthKit。

### Q10: 为什么照片只读元数据，而不读取图片内容？
**Answer**: 用户隐私是核心设计原则。读取图片内容（像素数据）会：1) 消耗大量内存；2) 产生隐私风险（用户可能不希望 App 分析照片内容）；3) App Store 审核更严格。元数据（拍摄时间、GPS 坐标、收藏标志）已足够实现"我最近在哪里拍了多少照片"的场景，且权限要求更低（Photos框架的只读权限 vs. 需要用户明确授权才能读取图片内容）。

---

## 附录：快速启动 / Quick Start

```bash
# 1. 安装 XcodeGen
brew install xcodegen

# 2. 生成 Xcode 项目
cd /Users/yaxinli/xym/iosagent
xcodegen generate

# 3. 打开 Xcode 项目
open PrivateAI.xcodeproj

# 4. 选择真机（HealthKit 需要真机）
# 5. 签名：Team → 你的 Apple ID
# 6. Build & Run
```

---

*文档版本 / Doc Version: v1.0 | 更新日期 / Updated: 2026-03-07*
