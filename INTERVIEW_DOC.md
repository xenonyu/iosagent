# PrivateAI — iOS 面试技术准备手册

> **一句话 Pitch**
> "这是一款 100% 本地运行的 AI 私人助理 iOS App，无任何网络请求，所有数据存储在用户设备上。我从零设计了意图识别引擎、多轮上下文记忆、以及覆盖 6 大系统框架的数据聚合层。"

---

## 目录

1. [整体架构](#1-整体架构)
2. [本地 AI 引擎](#2-本地-ai-引擎)
3. [CoreData 持久化层](#3-coredata-持久化层)
4. [系统框架集成](#4-系统框架集成)
5. [SwiftUI & MVVM](#5-swiftui--mvvm)
6. [Widget Extension](#6-widget-extension)
7. [工程化实践](#7-工程化实践)
8. [常见追问 & 回答模板](#8-常见追问--回答模板)

---

## 1. 整体架构

### 架构图

```
┌─────────────────────────────────────────────┐
│                  SwiftUI Views               │
│  Chat / Timeline / Stats / Profile / Settings│
└────────────────┬────────────────────────────┘
                 │ @EnvironmentObject / @StateObject
┌────────────────▼────────────────────────────┐
│              ViewModels (MVVM)               │
│  ChatViewModel / TimelineViewModel / ...     │
└──────┬──────────────────────┬───────────────┘
       │                      │
┌──────▼──────┐     ┌─────────▼──────────────┐
│  Local AI   │     │    Service Layer        │
│  Engine     │     │  Location / Health /    │
│  + Context  │     │  Calendar / Photos /    │
│  Memory     │     │  Speech / Notification  │
└──────┬──────┘     └─────────┬──────────────┘
       │                      │
┌──────▼──────────────────────▼──────────────┐
│           CoreData (SQLite, On-Device)       │
│  CDChatMessage / CDLifeEvent /              │
│  CDLocationRecord / CDUserProfile           │
└─────────────────────────────────────────────┘
```

### 核心设计原则

| 原则 | 实现方式 |
|------|----------|
| **Privacy by Design** | 无 `NSAllowsArbitraryLoads`，无任何 URLSession 网络请求 |
| **单一数据源** | CoreData 作为唯一存储，Widget 通过 App Group UserDefaults 共享 |
| **权限最小化** | 每项系统权限独立开关，用户可随时撤销，数据随之清空 |
| **响应优先** | AI 响应在后台线程组装，`DispatchQueue.main.async` 更新 UI |

---

## 2. 本地 AI 引擎

> **亮点**: 无任何第三方 AI SDK，完全自研的 NLP + 推理链路

### 2.1 意图识别 — `IntentParser`

**技术点**: 基于关键词权重的规则式 NLP，支持中英文混合输入

```
用户输入 → parse() → 关键词匹配 → QueryIntent
                  ↓
             extractTimeRange()    → QueryTimeRange (today/week/month...)
             extractHealthMetric() → "睡眠/步数/心率"
             parseAddEvent()       → 自动创建 LifeEvent
```

**支持的 16 种意图**:
`exercise` / `location` / `mood` / `health` / `calendar` / `photos` /
`summary` / `recommendation` / `profile` / `addEvent` / `streak` /
`weeklyInsight` / `comparison` / `photoSearch` / `events` / `unknown`

**面试追问准备**:
- Q: "规则式 NLP 的局限是什么？" → A: "对长句、模糊表达、语义相近词支持差。下一步计划接入 Core ML + CreateML 训练的本地文本分类模型，保持离线特性的同时提升准确率。"

### 2.2 推理引擎 — `LocalAIEngine`

**技术点**: 数据聚合 + 模板化自然语言生成

```swift
// 核心分发逻辑
func respond(to query: String, preResolvedIntent: QueryIntent? = nil) {
    let intent = preResolvedIntent ?? IntentParser.parse(query)
    switch intent {
    case .exercise:   respondExercise()
    case .location:   respondLocation()   // 地点聚合 + 访问频次统计
    case .mood:       respondMood()       // Emoji 分布可视化
    case .streak:     respondStreak()     // 连续达标天数计算
    case .comparison: respondComparison() // 本周 vs 上周对比
    // ...
    }
}
```

**亮点细节**:
- `respondStreak()`: 倒序遍历每日步数，计算"连续达到 8000 步"的天数链，算法复杂度 O(n)
- `respondComparison()`: 用 `DispatchGroup` 并行拉取两周数据，避免串行等待
- `buildGPTPrompt()`: 将本地数据结构化为自然语言 prompt，预留外部 LLM 扩展接口

### 2.3 多轮上下文记忆 — `ContextMemory`

**技术点**: 滑动窗口式对话状态机

```
对话历史 (max 12条) ─┐
最近意图             ├──→ resolveIntent() ──→ 继承上文意图
提及的人名/话题       │                        (处理"那...呢?"追问)
最近时间范围         ─┘
```

**关键设计**:
```swift
func resolveIntent(from query: String) -> QueryIntent? {
    // "那上周呢" / "再看看" / "还有吗" → 继承 lastIntent
    let followUpKeywords = ["那", "再", "还有", "继续", "呢", "then", "also"]
    if containsAny(query, followUpKeywords), let last = lastIntent {
        return last
    }
    return nil
}
```

---

## 3. CoreData 持久化层

### 数据模型 (4 实体)

```
CDChatMessage          CDLifeEvent
├── id: UUID           ├── id: UUID
├── content: String    ├── title: String
├── isUser: Bool       ├── mood: String
└── timestamp: Date    ├── category: String
                       ├── tags: Data (JSON)
CDLocationRecord       └── timestamp: Date
├── latitude: Double
├── longitude: Double   CDUserProfile
├── placeName: String   ├── name: String
└── timestamp: Date     ├── birthday: Date
                        ├── interests: Data (JSON)
                        └── familyMembers: Data (JSON)
```

### 技术亮点

**1. 并发安全写入**
```swift
// 后台写，主线程读，避免 UI 卡顿
let bgContext = PersistenceController.shared.newBackgroundContext()
bgContext.perform {
    CDLocationRecord.create(in: bgContext, from: record)
    try? bgContext.save()
}
```

**2. Merge Policy 策略选择**
```swift
container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
// 选择"新值覆盖旧值"策略，确保 UI 展示永远是最新数据
```

**3. CoreData Extensions 设计模式**
```swift
// 统一 CRUD 接口，View 层零 CoreData 依赖
extension CDChatMessage {
    static func fetchAll(context:) -> [ChatMessage]
    static func create(in:from:)
    static func deleteAll(context:)
}
```

**面试追问准备**:
- Q: "为什么不用 SwiftData？" → A: "项目支持 iOS 16+，SwiftData 需要 iOS 17+，CoreData 保证了更广的设备覆盖率。"
- Q: "如何处理迁移？" → A: "启用了 `NSMigratePersistentStoresAutomaticallyOption` + `NSInferMappingModelAutomaticallyOption`，支持轻量级自动迁移。"

---

## 4. 系统框架集成

### 4.1 CoreLocation — 后台位置追踪

**技术亮点: Significant Location Change（显著位置变化监听）**

```swift
locationManager.startMonitoringSignificantLocationChanges()
// vs startUpdatingLocation() — 节省 90%+ 电量
```

**防抖逻辑**:
```
新位置到达 → 距离 > 200m? → 时间间隔 > 5min? → 反向地理编码 → 存 CoreData
                ↓ No              ↓ No
              丢弃              丢弃
```

**权限流程**: `WhenInUse` → `Always`（后台追踪必须 Always）

### 4.2 HealthKit — 健康数据读取

**架构亮点**: 并发查询多个指标，DispatchGroup 统一回调

```swift
func fetchDailySummary(for date: Date, completion: @escaping (HealthSummary) -> Void) {
    let group = DispatchGroup()

    group.enter(); fetchSum(.stepCount, ...) { steps in group.leave() }
    group.enter(); fetchSum(.activeEnergyBurned, ...) { cal in group.leave() }
    group.enter(); fetchAverage(.heartRate, ...) { hr in group.leave() }
    group.enter(); fetchSleepHours(...) { sleep in group.leave() }

    group.notify(queue: .main) { completion(summary) }
}
```

**只读原则**: 只申请 `HKObjectType.quantityType` 读权限，从不写入

### 4.3 EventKit — 日历读取

**技术点**: iOS 16/17 兼容处理

```swift
// iOS 17+ 新 API
if #available(iOS 17.0, *) {
    let granted = try await store.requestFullAccessToEvents()
} else {
    store.requestAccess(to: .event) { granted, _ in ... }
}
```

### 4.4 Photos Framework — 元数据索引

**隐私亮点**: 只读取元数据，永不解码图片像素

```swift
// PHAsset 只获取：date / location / isFavorite
// 不调用 PHImageManager.requestImage() — 图片内容永不触碰
let assets = PHAsset.fetchAssets(with: .image, options: options)
assets.enumerateObjects { asset, _, _ in
    let meta = PhotoMeta(
        date: asset.creationDate,
        coordinate: asset.location?.coordinate,
        isFavorite: asset.isFavorite
    )
}
```

### 4.5 Speech Framework — 本地语音识别

```swift
// 强制指定本地识别，不上传服务器
let request = SFSpeechAudioBufferRecognitionRequest()
request.requiresOnDeviceRecognition = true  // 关键！
```

### 4.6 UserNotifications — 本地通知系统

**通知类型**:
| 类型 | 触发时机 | 内容生成 |
|------|----------|----------|
| 每日提醒 | 用户设置时间 | 根据当天步数动态生成激励文案 |
| 每周摘要 | 每周日 9:00 | 聚合一周事件数 + 地点数 |

---

## 5. SwiftUI & MVVM

### 状态管理层级

```
App Level:   AppState (@EnvironmentObject) — 全局权限、服务实例
View Level:  ChatViewModel (@StateObject)  — 消息列表、语音状态
             StatsViewModel               — 图表数据、时间范围选择
```

### 性能优化点

**LazyVStack for 消息列表**
```swift
ScrollView {
    LazyVStack {   // 只渲染可见 cell，O(1) 内存
        ForEach(messages) { msg in MessageBubble(msg) }
    }
}
```

**@AppStorage for 持久化配置**
```swift
@AppStorage("locationEnabled") var locationEnabled = false
// 直接绑定 UserDefaults，无需手动 save/load
```

### Swift Charts (iOS 16+)

StatsView 中实现了 6 种图表类型：

```swift
Chart(data) {
    BarMark(x: .value("日期", $0.date), y: .value("步数", $0.steps))
        .foregroundStyle(Color.accentColor.gradient)  // 渐变色
}
.chartXAxis { AxisMarks(values: .stride(by: .day)) }
```

---

## 6. Widget Extension

### App Group 数据共享

```
PrivateAI App          WidgetExtension
      │                      │
      └──→ UserDefaults ←───┘
           (group: com.privateai.shared)
           today_steps / today_calories / today_sleep
```

```swift
// 主 App 写入，Widget 刷新
UserDefaults(suiteName: "group.com.privateai.shared")?
    .set(steps, forKey: "today_steps")
WidgetCenter.shared.reloadAllTimelines()
```

**Timeline Provider**: Widget 独立从 HealthKit 读取数据，不依赖主 App 进程

---

## 7. 工程化实践

### XcodeGen — 代码化项目配置

```yaml
# project.yml (部分)
targets:
  PrivateAI:
    type: application
    platform: iOS
    deploymentTarget: "16.0"
    dependencies:
      - sdk: HealthKit.framework
      - sdk: EventKit.framework
      - sdk: Photos.framework
      - sdk: UserNotifications.framework
```

**优势**: `project.pbxproj` 不再手动管理，Git 冲突减少 90%

### CoreData codeGenerationType

```
// 使用 "class" 模式 — Xcode 自动生成 NSManagedObject 子类
// 避免手写样板代码，schema 变更只需修改 .xcdatamodeld
```

### 架构扩展性设计

- `LocalAIEngine.buildGPTPrompt()` — 预留外部 LLM 扩展接口，可一键接入 Core ML
- 所有 Service 均为 `ObservableObject`，可无缝替换 mock 实现用于测试
- `QueryTimeRange` enum 封装日期区间计算，AI 层与 UI 层解耦

---

## 8. 常见追问 & 回答模板

### 架构类

**Q: 为什么选择 MVVM 而不是 MVC？**
> "在 SwiftUI 中，View 本身已经是声明式的状态映射，MVVM 的 ViewModel 天然对应 `@StateObject`/`@ObservedObject`。相比 MVC，业务逻辑与 UI 解耦更清晰，单个 ViewModel 也更容易单独测试。"

**Q: AppState 作为 EnvironmentObject 会不会导致不必要的重绘？**
> "是潜在问题。优化方向是将 AppState 拆分成更细粒度的 ObservableObject（如 PermissionState、ServiceState），让子 View 只订阅自己需要的状态。目前项目规模下影响可接受。"

### 性能类

**Q: CoreData 查询大量数据时如何优化？**
> "1. 使用 `fetchBatchSize` 分批加载；2. 只 `fetch` 需要的属性（`propertiesToFetch`）；3. 后台 context 执行耗时查询，结果 `perform` 到主线程；4. 为常用查询字段建 index。"

**Q: 位置数据量会不会很大？**
> "Significant Location Change 模式下，用户一天正常出行大概产生 5-20 条记录。加上 200m + 5min 防抖，实测一周数据在 1000 条以内，SQLite 完全可以处理。"

### 隐私类

**Q: 如何向用户证明数据不出设备？**
> "1. App 没有申请网络权限；2. Info.plist 无 ATS 配置；3. 代码中无任何 URLSession 调用。可以在断网状态下完整运行所有功能。"

### 扩展性类

**Q: 如果要接入真正的 LLM 怎么做？**
> "已预留 `buildGPTPrompt()` 方法，将本地数据结构化为上下文 prompt。两种路径：1. Core ML 本地模型（保持隐私）；2. 可选网络模式下调用 API（用户明确授权）。`RawGPTService.swift` 是这个扩展点的占位实现。"

---

*Generated for interview preparation — PrivateAI v2.0*
