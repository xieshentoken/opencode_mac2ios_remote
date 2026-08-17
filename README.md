# OpenCodeMobile

原生 iOS (SwiftUI) 客户端，用于远程连接运行在 macOS 上的
[OpenCode](https://github.com/sst/opencode) AI 编程代理（headless
`opencode serve`）。界面复刻 opencode TUI 的视觉风格：SF Mono 等宽字体、
深色主题、像素风边框、底部状态栏。

> 本项目不包含任何 fork 或中间层：App 直接通过 HTTP + SSE 与
> `opencode serve` 通信，零依赖、零中间服务。

---

## 功能特性

- **远程连接**：通过 HTTPS（推荐 Cloudflare Tunnel）连接 Mac 上的
  `opencode serve`，支持 HTTP Basic 认证（用户名 + 密码）。
- **会话管理**：列出/切换/新建/删除会话；多目录（workspace）路由，
  每个目录独立会话流。
- **流式输出**：基于 SSE 的 `message.part.delta` 实时增量渲染；
  自动重连 + 断线补拉（reconcile）。
- **REST 轮询回退**：当 SSE 被网络缓冲（如 Cloudflare quick tunnel）
  时自动降级为每 4 秒轮询，任务状态仍可跟踪。
- **权限审批**：收到 `permission.asked` 时弹出 TUI 风格对话框，
  支持 once / always / reject 回复；多个待审批请求可依次处理。
- **Markdown 双模式**：源码模式（TUI 原样）与渲染模式（标题/列表/
  引用/代码块/GFM 表格）一键切换——点顶部机器人切换。
- **@file 文件树**：浏览服务器工作区文件，支持模糊搜索与
  `@相对路径` 插入。
- **模型与思考等级**：模型列表动态读取 Mac 真实配置；支持
  `minimal/low/medium/high/xhigh/max` 思考等级（variant）。
- **build/plan 双模式**：快捷切换 agent 模式。
- **Provider 管理**：查看 Mac 上已配置的 provider，添加/删除 API key
  （存储于系统 Keychain），内置常用平台预设与用量统计。
- **App 图标 / 横屏 / 键盘适配**：自定义像素图标，支持横屏，
  键盘弹出时会话自动上移并保持最新内容可见。

---

## 目录结构

```
OpenCodeMobile/
├── OpenCodeMobile/            # App 源码
│   ├── App/                   # 入口 + AppState（全局状态/SSE 分发）
│   ├── API/                   # OpenCodeClient / EventStream / Keychain
│   ├── Models/                # Codable 模型（容错解码）
│   ├── Theme/                 # TUI 像素风主题 + 像素图形
│   └── Views/                 # Chat / Sessions / Projects / Settings
├── Launcher/                  # macOS 一键启动脚本（serve + 隧道）
├── project.yml                # XcodeGen 工程定义
└── OpenCodeMobile.xcodeproj   # 已生成的 Xcode 工程
```

---

## 环境要求

| 端 | 要求 |
|---|---|
| 客户端 | iPhone/iPad，iOS 17+ |
| 构建机 | macOS + Xcode 15+（含 iOS 17 SDK）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)（可选） |
| 服务端 | macOS，安装 [opencode](https://opencode.ai/docs/) CLI |
| 隧道（可选） | `cloudflared`（Quick Tunnel 免配置） |

---

## 一、服务端部署（macOS）

### 1. 启动 opencode serve

```bash
# 设置访问密码（重要：App 连接需要认证）
export OPENCODE_SERVER_PASSWORD="你的密码"

# 监听本机 4096 端口
opencode serve --port 4096 --hostname 127.0.0.1
```

> - HTTP Basic 认证：用户名固定为 `opencode`，密码即上面的变量值。
> - 首次使用前建议先在本机运行一次 `opencode` 完成登录/配置 provider
>   API key（`opencode auth login` 或写入 `~/.local/share/opencode/auth.json`）。

### 2. 暴露到公网（App 远程连接用）

**方式 A：Cloudflare Quick Tunnel（最快，有 SSE 限制，见"已知限制"）**

```bash
cloudflared tunnel --url http://127.0.0.1:4096 --protocol http2
```

启动后会打印一个 `https://xxxx.trycloudflare.com` 地址，填进 App 即可。

> 如果你的网络环境 QUIC 被封锁（如某些代理/VPS），务必加
> `--protocol http2`，否则隧道永远连不上（错误 1033）。

**方式 B：Cloudflare 命名隧道 + 自定义域名（推荐，SSE 正常流式）**

```bash
cloudflared tunnel create opencode
cloudflared tunnel route dns opencode chat.example.com
# 然后配置 tunnel config 将 https://chat.example.com 转发到 http://127.0.0.1:4096
cloudflared tunnel run opencode
```

### 3. 使用内置启动器（可选）

仓库内 `Launcher/` 提供一键脚本，自动完成 serve + 隧道：

```bash
chmod +x Launcher/launcher.sh Launcher/start.command
./Launcher/launcher.sh start   # 启动 serve(4096) + cloudflared 隧道
./Launcher/launcher.sh status  # 查看状态
./Launcher/launcher.sh url     # 打印当前隧道地址
./Launcher/launcher.sh stop    # 停止隧道（serve 保留）
```

配置文件：`~/opencode-mobile/server.conf`

```bash
OPENCODE_SERVER_PASSWORD=你的密码
```

日志：`~/opencode-mobile/opencode.log`、`~/opencode-mobile/tunnel.log`。

---

## 二、客户端构建

### 1. 生成工程（可选）

若已安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
cd OpenCodeMobile
xcodegen generate
```

仓库已包含生成的 `OpenCodeMobile.xcodeproj`，可直接使用。

### 2. 打开并签名

```bash
open OpenCodeMobile.xcodeproj
```

- 在 **Signing & Capabilities** 中选择你自己的开发团队
  （真机运行必须；模拟器可留空）。
- Bundle ID：`dev.opencodemobile.app`（可在 `project.yml` 修改后重新
  `xcodegen generate`）。

### 3. 运行

- 模拟器：直接 ⌘R。
- 真机：连接 Mac，选择你的设备，⌘R 安装。

---

## 三、使用指南

### 1. 添加服务器

首次启动进入设置 → **Server**，填写：

- **URL**：`https://xxxx.trycloudflare.com`（或你的自定义域名）
- **用户名**：`opencode`
- **密码**：启动 serve 时设置的 `OPENCODE_SERVER_PASSWORD`

凭据保存在 iOS Keychain，不落盘明文。

### 2. 主界面

| 元素 | 操作 |
|---|---|
| 顶部机器人 | 单击：切换 Markdown 渲染模式（眼睛 `. .` → `> <`）；长按：会话切换器 |
| 顶部 `[ : ]` | 菜单（切换会话/项目、新建会话/项目、服务器设置） |
| 顶部 `[ + ]` | 新建项目 |
| 输入框 `[↵]` | 发送；运行中变 `[■]` 为中止 |

### 3. 快捷栏（输入框下方）

- `@file`：插入 `@相对路径`（可浏览文件树/搜索）
- `模型名`：切换模型（来自 Mac 真实配置）
- `build/plan`：切换 agent 模式
- `default/low/high/max`：思考等级（模型支持时显示）
- `skill` / `commands`：技能 / 命令面板

### 4. 权限审批

任务需要操作工作区外文件、执行命令等时会弹出审批框：
`[once]` 仅本次允许，`[always]` 总是允许，`[reject]` 拒绝。

> 注意：同一任务可能连续触发多个审批，请逐一处理。

### 5. Provider 管理（设置 → Provider）

- 顶部列表：Mac 上已配置的 provider（含用量统计）。
- `[used]`：打开对应平台的用量控制台。
- `[del]`：删除该 provider 的 API key。
- 底部添加区：选择预设（Anthropic/OpenAI/xAI/Gemini/Moonshot/GLM/
  Qwen/DeepSeek/OpenCode 等），填入 API key 即可推送至 Mac。

> `GET /config/providers` 的列表在 serve 启动时缓存：新添加的
> provider 需重启 `opencode serve` 后才会出现在真实配置列表，
> 但 App 会立即在本地合并显示。

### 6. 调试启动参数（模拟器/CI）

| 参数 | 作用 |
|---|---|
| `-OCServerURL <url>` | 直接指定服务器 URL（免手动配置） |
| `-OCServerUser <u>` / `-OCServerPass <p>` | 认证凭据 |
| `-OCRendered` | 启动即 Markdown 渲染模式 |
| `-OCSessionID <id>` | （DEBUG）直接加载指定会话 |
| `-OCE2E` | （DEBUG）自动端到端测试（建会话→发提示→自动审批→断言） |
| `-OCE2EDir/-OCE2EPrompt/-OCE2EDelay` | E2E 参数定制 |

示例：

```bash
xcrun simctl launch booted dev.opencodemobile.app \
  -OCServerURL https://xxxx.trycloudflare.com \
  -OCServerUser opencode -OCServerPass 你的密码
```

---

## 安全说明

- 服务器密码 / provider API key 均存储于系统 **Keychain**，代码中不含
  任何真实凭据。
- App 与 serve 之间的流量应始终走 HTTPS（Cloudflare Tunnel 自动提供）。
- 请勿将 `OPENCODE_SERVER_PASSWORD`、API key 提交到 Git。

---

## 已知限制

1. **Cloudflare Quick Tunnel 会缓冲 SSE**：`/event` 返回 200 但
   不推送任何字节。App 会降级为 REST 轮询（约 4 秒刷新一次）；
   但**权限审批在 quick tunnel 下不可用**（服务端收不到回复会一直
   挂起）。需要完整流式体验请使用命名隧道 + 自定义域名。
2. **QUIC 被封锁的网络**：`cloudflared` 必须加 `--protocol http2`。
3. **provider 列表启动缓存**：添加/删除 provider 后需重启 serve
   才在真实配置中生效（App 有本地即时合并作为过渡）。
4. **SSE 会话流按目录隔离**：App 为每个活动目录维护独立的 SSE 连接，
   切换项目时自动切换。

---

## 技术要点

- iOS 17+，SwiftUI，无第三方依赖。
- 事件分发：`AppState.handleSSEEvent` 处理 `message.*`、`permission.*`、
  `session.*`、`tool` 等事件。
- 容错解码：所有 Codable 模型字段可选，未知事件静默跳过，容忍服务端
  版本漂移；通过 `GET /global/health` 做版本检查。
- 流式文本：`message.part.delta` 增量追加到当前 assistant 消息。
- 会话长度：历史消息拉取上限 1000 条（`GET /session/:id/message?limit=`）。

## License

MIT license
