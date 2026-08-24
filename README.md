# OpenCode Mobile / OpenCode 移动端

一款面向 iPhone 和 iPad 的原生 SwiftUI 客户端，用于从移动端远程使用运行在 Mac 上的 AI 编程代理。当前 App 已接入 **OpenCode** 与 **Hermes Agent** 两种后端，并针对没有固定域名、只能使用 Cloudflare Quick Tunnel 的环境提供明确的传输降级策略。

A native SwiftUI client for iPhone and iPad that remotely controls AI coding agents running on a Mac. The app currently supports two backends—**OpenCode** and **Hermes Agent**—and includes explicit transport fallbacks for environments that rely on changing Cloudflare Quick Tunnel hostnames instead of a fixed domain.

> 当前状态 / Current status: OpenCode 和 Hermes 已进入同一个 iOS 客户端；DeepSeek Harness 尚未接入，也不包含在本仓库中。/ OpenCode and Hermes are integrated into the iOS client. DeepSeek Harness is not yet integrated or included in this repository.

## 目录 / Contents

- [中文说明](#中文说明)
- [English](#english)
- [仓库状态与许可证 / Repository status and licensing](#仓库状态与许可证--repository-status-and-licensing)

---

## 说明

### 项目功能

#### 通用能力

- 原生 iOS 17+ SwiftUI 界面，使用 SF Mono、深色主题和 TUI 风格控件；不渲染 SSH 终端。
- 保存和切换多个服务器，并为每个服务器记录后端类型（OpenCode 或 Hermes）。
- 服务器密码存入 iOS Keychain；持久化配置和诊断信息不包含明文密码。
- 支持会话列表、历史消息、流式文本、推理过程、工具状态、中断任务和后台权限通知。
- iOS 前后台切换后重新连接，并通过服务端历史记录校准本地消息。
- 远端凭据只允许通过 HTTPS 发送；仅回环地址允许 HTTP 调试。

#### OpenCode 后端

- 直接连接 `opencode serve`，没有自建业务中间层。
- 会话的新建、切换、删除、历史加载和异步 Prompt。
- 按工作目录路由项目；每个活动目录维护独立的 SSE 事件流。
- 支持模型、Provider、Agent、Command、Skill、MCP 状态及 `@file` 文件浏览。
- 支持 `message.part.delta` 增量文本、Reasoning 和 Tool 生命周期。
- 处理多个 `permission.asked` 请求，支持 `once`、`always` 和 `reject`。
- 普通 HTTPS 域名优先使用 SSE；检测到 `*.trycloudflare.com` 后直接采用自适应 REST 轮询，避免先等待无输出的 SSE 超时。
- REST 轮询初期约每 0.75 秒刷新，随后逐步退避到 4 秒；任务结束前会再拉取一次最终消息。

#### Hermes 后端

- 面向 Hermes Agent 0.19.1 的 Dashboard REST API 和 Gateway WebSocket JSON-RPC。
- 使用密码登录、内存中的 HttpOnly Cookie 以及一次性 WebSocket Ticket；Ticket 不持久化。
- 支持会话列表、历史记录、新建/恢复/删除会话、提交 Prompt 和中断。
- 实时处理文本、推理、工具进度、审批、澄清、`sudo` 和 Secret 输入事件。
- 将持久化的 Dashboard 会话 ID 与每次连接生成的运行时会话 ID 分开管理。
- WebSocket 断开后使用新 Ticket 指数退避重连，并重新附着活动会话。
- 如果本机 VPS、代理或中间设备拦截 WebSocket Upgrade，App 会降级为经过认证的 REST 只读历史模式；不会自动通过另一协议重发 Prompt，以免工具执行两次。
- Hermes 0.19.1 的危险命令审批没有 Request ID，因此客户端严格按会话 FIFO 展示和回复。请及时核对当前命令；要彻底消除歧义仍需要 Hermes 服务端增加 Request ID 或命令摘要校验。

### 依赖环境

| 位置 | 必需环境 | 说明 |
|---|---|---|
| iOS 客户端 | iPhone/iPad，iOS 17+ | 真机使用需要 Apple Development 签名，并在设备上信任开发者证书 |
| 构建 Mac | macOS、Xcode 15.3+ | 项目使用 Swift 5.10；推荐使用当前稳定版 Xcode |
| 工程生成 | XcodeGen（可选） | 仓库已包含 `.xcodeproj`，只有修改 `project.yml` 后才需要重新生成 |
| OpenCode 服务端 | OpenCode CLI；协议已按 1.18.18 验证 | API 变化较快，升级后建议重新检查 `GET /doc` |
| Hermes 服务端 | Hermes Agent 0.19.1 | 默认启动器路径为 `~/.local/bin/hermes` |
| 公网入口 | `cloudflared` | 不需要 Cloudflare 账号即可使用 Quick Tunnel；本网络必须加 `--protocol http2` |

iOS App 本身不使用 CocoaPods、Carthage 或第三方 Swift Package。DeepSeek Harness 不包含在本仓库中，也不是构建依赖。

### 快速开始

#### 1. 构建 iOS App

仓库已经包含生成好的 Xcode 工程：

```sh
open OpenCodeMobile.xcodeproj
```

在 Xcode 中：

1. 选择 `OpenCodeMobile` Target。
2. 在 **Signing & Capabilities** 中选择自己的 Team。
3. 选择模拟器或已配对的 iPhone/iPad。
4. 按 `⌘R` 构建并运行。
5. Personal Team 首次真机安装后，在 iPhone 的“设置 → 通用 → VPN 与设备管理”中信任开发者 App。

如果修改了 `project.yml`：

```sh
xcodegen generate
```

#### 2. 启动 OpenCode

先安装并完成 OpenCode 的模型/Provider 配置，然后创建受保护的启动器配置：

```sh
mkdir -p "$HOME/opencode-mobile"
chmod 700 "$HOME/opencode-mobile"
```

在 `~/opencode-mobile/server.conf` 中写入：

```sh
OPENCODE_SERVER_PASSWORD='请替换为唯一强密码'
```

设置权限并启动：

```sh
chmod 600 "$HOME/opencode-mobile/server.conf"
cd Launcher
chmod +x launcher.sh
./launcher.sh start
./launcher.sh url
```

启动器会运行：

```text
opencode serve --port 4096 --hostname 127.0.0.1
cloudflared tunnel --url http://127.0.0.1:4096 --protocol http2
```

在 App 的 Server Settings 中新增：

| 字段 | 值 |
|---|---|
| Agent | `OpenCode` |
| URL | `./launcher.sh url` 输出的 `https://…trycloudflare.com` |
| Username | `opencode` |
| Password | `OPENCODE_SERVER_PASSWORD` 的值 |

Quick Tunnel 域名每次重新启动可能变化。域名变化后请编辑原有服务器记录，而不是删除重建，这样可复用稳定的配置 ID 和 Keychain 条目。

常用命令：

```sh
./launcher.sh status
./launcher.sh url
./launcher.sh stop
```

`stop` 只停止公网隧道，保留 `opencode serve`。

#### 3. 启动 Hermes

先安装 Hermes Agent 0.19.1，并确认以下命令存在：

```sh
"$HOME/.local/bin/hermes" --version
```

初始化认证并启动独立的 Hermes Quick Tunnel：

```sh
cd Launcher
./launcher.sh init-hermes
./launcher.sh start-hermes
./launcher.sh url-hermes
```

`init-hermes` 会交互式创建 `~/opencode-mobile/hermes.conf`，其中仅保存 scrypt 密码哈希和随机签名 Secret，不保存原密码。

在 App 中新增：

| 字段 | 值 |
|---|---|
| Agent | `Hermes` |
| URL | `./launcher.sh url-hermes` 输出的 URL |
| Username | 初始化时设置的用户名，默认 `admin` |
| Password | `init-hermes` 时输入的原密码 |

常用命令：

```sh
./launcher.sh status-hermes
./launcher.sh url-hermes
./launcher.sh stop-hermes
```

Hermes 0.19.1 只有在非回环监听时才启用 Dashboard Basic Auth，因此启动器使用 `0.0.0.0:9119`，但在创建公网隧道前会验证：

- `/api/status` 明确报告 `auth_required=true`；
- 匿名访问受保护接口返回 401 或 403；
- 配置文件权限为 `600`。

任一检查失败时，启动器会拒绝暴露服务。

### App 使用方法

1. 首次打开 App，进入 Server Settings。
2. 选择 OpenCode 或 Hermes，填写名称、动态 Tunnel URL、用户名和密码。
3. 点击 `[ test ]`：OpenCode 校验 Health；Hermes 会进一步校验 `gateway.ready`，不会把 REST 登录成功误判为可执行连接。
4. 点击 `[ save + connect ]`。
5. 从会话列表新建或恢复会话，在输入框发送 Prompt；运行中可点击停止按钮中断。
6. 出现权限、澄清、sudo 或 Secret 请求时，核对内容后在 App 内回复。敏感输入使用安全输入框。
7. Quick Tunnel URL 变化后编辑保存的服务器 URL，再重新连接。

OpenCode 专属入口（项目、Provider、模型、Agent、MCP、文件树等）在 Hermes 连接下不会误显示为可用。Hermes 的 WebSocket 失败时仍可读取会话历史，但发送 Prompt、新建/删除会话和交互回复会被禁用。

### 技术架构

```text
┌──────────────────────────────── iOS App ────────────────────────────────┐
│ SwiftUI Views                                                          │
│ Chat · Sessions · Projects · Settings · Permission/Input dialogs       │
│                                │                                       │
│                         @MainActor AppState                             │
│  server routing · session state · reconciliation · transport fallback  │
│                    ┌───────────┴───────────┐                            │
│                    │                       │                            │
│          OpenCode adapter           Hermes adapter                     │
│ OpenCodeClient + OpenCodeAPI   HermesClient + HermesGatewaySocket       │
│      REST + per-dir SSE         REST auth/history + WSS JSON-RPC        │
└────────────────────┬───────────────────────┬────────────────────────────┘
                     │ HTTPS                │ HTTPS / WSS
             Cloudflare Quick Tunnel（动态域名 / changing hostname）
                     │                      │
        opencode serve :4096       hermes serve :9119
                     └──────────── macOS host ────────────┘
```

#### 客户端分层

| 层 | 主要文件 | 职责 |
|---|---|---|
| UI | `Views/`、`Theme/` | 原生 TUI 风格界面、聊天、会话、项目、设置和审批 |
| 状态编排 | `App/AppState.swift` | 后端路由、连接生命周期、会话映射、消息合并、重连和降级 |
| OpenCode REST | `API/OpenCodeClient.swift`、`API/OpenCodeAPI.swift` | 长生命周期 `URLSession`、Basic Auth、目录 Header/Query、API 封装 |
| OpenCode 事件 | `API/EventStream.swift` | 每目录 SSE、90 秒空闲超时、自动重连、前台恢复校准 |
| Hermes REST | `API/HermesClient.swift` | 状态探针、登录、内存 Cookie、一次性 WS Ticket、只读历史 |
| Hermes 实时层 | `API/HermesGatewaySocket.swift` | Actor 隔离的 WebSocket、JSON-RPC、超时、Ping 和强类型操作 |
| 协议模型 | `Models/` | 宽松 Codable/JSON Value、未知字段容忍、持久/运行时 ID 分离 |
| 凭据 | `API/KeychainStore.swift` | Keychain 保存密码，UserDefaults 只保存脱敏服务器配置 |
| macOS 启动 | `Launcher/launcher.sh` | 两套独立服务和隧道、动态 URL、认证 Fail-closed 检查 |

#### 传输协议对比

| 后端 | 认证 | 历史/配置 | 实时控制 | 失败策略 |
|---|---|---|---|---|
| OpenCode + 普通 HTTPS 域名 | HTTP Basic | REST | 每活动目录一个 SSE | 90 秒静默重连，并用 REST 校准 |
| OpenCode + Quick Tunnel | HTTP Basic | REST | Quick Tunnel 会缓冲 SSE | 直接使用 0.75–4 秒自适应 REST 轮询 |
| Hermes | Password Login + HttpOnly Cookie + 单次 Ticket | Dashboard REST | `/api/ws` WSS JSON-RPC | 指数退避重连；失败时只读，不自动重放 Prompt |

#### 重要设计约束

- OpenCode 的 `/event` 是目录实例级而不是全局流；切换项目必须切换 `x-opencode-directory`。
- App 使用长期复用的网络客户端，避免每次操作重新进行 DNS、TCP、TLS 和 HTTP/2 建连。
- OpenCode SSE 增量会先按消息 Part 合并，再批量更新 SwiftUI，降低主线程刷新频率。
- iOS 回到前台后总是重新连接并从 REST 历史校准，不能假设后台 SSE/WSS 仍存活。
- Hermes Prompt 如果在 WebSocket 故障时交付状态不确定，客户端只提示风险，不自动重发。
- 所有协议模型都尽量容忍新增字段和未知事件，但服务端升级后仍应运行协议测试。

### 测试

测试 Target 为 `OpenCodeMobileTests`，目前覆盖传输选择、旧配置迁移、密码不落盘、OpenCode 目录路由、Hermes 认证/Cookie/Ticket、协议宽松解码、持久与运行时 ID、审批 FIFO 和凭据脱敏错误信息。

模拟器示例：

```sh
xcodebuild test \
  -project OpenCodeMobile.xcodeproj \
  -scheme OpenCodeMobile \
  -destination 'platform=iOS Simulator,name=<已安装的模拟器名称>'
```

真机示例：

```sh
xcodebuild test \
  -project OpenCodeMobile.xcodeproj \
  -scheme OpenCodeMobile \
  -destination 'id=<DEVICE_UDID>' \
  DEVELOPMENT_TEAM=<TEAM_ID> \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration
```

真机首次运行前必须在设备上信任开发者证书。

### 已知限制

1. Cloudflare Quick Tunnel 域名不固定；重启后需要在 App 中更新 URL。
2. OpenCode Quick Tunnel 会缓冲 SSE。REST 轮询能获取输出和结束状态，但无法主动收到 `permission.asked`；需要审批的任务可能停住。
3. Hermes 依赖 WebSocket 执行写操作。若本机 VPS/代理拦截 Upgrade，只能进入 REST 只读模式。
4. Hermes 0.19.1 的审批事件没有 Request ID，FIFO 只能降低错配风险，不能修复服务端静默超时后的身份歧义。
5. OpenCode API 与 Hermes Gateway 都在快速演进；这里的协议边界分别以 OpenCode 1.18.18 和 Hermes 0.19.1 为当前基线。
6. DeepSeek Harness 尚无对应的 Swift Adapter、认证映射或实时事件协议，因此不能在 App 的服务器类型中选择，也不包含在本仓库中。

### 目录结构

```text
.
├── README.md                       # 本文档 / this document
├── .gitignore                      # Xcode、日志和凭据忽略规则
├── project.yml                     # XcodeGen 定义
├── OpenCodeMobile.xcodeproj/       # 已生成的 Xcode 工程
├── OpenCodeMobile/                 # Swift 源码、资源和 Info.plist
├── OpenCodeMobileTests/            # XCTest 协议与传输测试
└── Launcher/                       # OpenCode + Hermes macOS 启动器
```

---

## Description

### Features

#### Shared client capabilities

- Native iOS 17+ SwiftUI interface using SF Mono, a dark palette, and TUI-inspired controls; it is not an SSH terminal emulator.
- Multiple saved servers with an explicit backend type: OpenCode or Hermes.
- Passwords are stored in the iOS Keychain; persisted server metadata and diagnostics do not contain plaintext passwords.
- Session lists, transcript history, streaming text, reasoning, tool state, task interruption, and background approval notifications.
- Foreground reconnection and transcript reconciliation after iOS suspends the live transport.
- Remote credentials require HTTPS; plaintext HTTP is allowed only for loopback development.

#### OpenCode backend

- Direct connection to `opencode serve` with no custom application middleware.
- Create, switch, delete, and reload sessions; submit asynchronous prompts.
- Workspace routing by directory, with one independent SSE stream for each active directory.
- Runtime catalogs for models, providers, agents, commands, skills, MCP status, and `@file` browsing.
- Incremental `message.part.delta`, reasoning, and tool lifecycle rendering.
- Multiple pending `permission.asked` requests with `once`, `always`, and `reject` replies.
- SSE for normal HTTPS hosts. Known `*.trycloudflare.com` hosts go directly to adaptive REST polling instead of first waiting for a silent SSE timeout.
- Polling starts around 0.75 seconds and gradually backs off to 4 seconds, followed by a final transcript fetch after the task becomes idle.

#### Hermes backend

- Dashboard REST and Gateway WebSocket JSON-RPC integration targeting Hermes Agent 0.19.1.
- Password login, an in-memory HttpOnly cookie, and a fresh single-use WebSocket ticket; tickets are never persisted.
- List, inspect, create, resume, and delete sessions; submit prompts and interrupt active work.
- Live text, reasoning, tool progress, approvals, clarification, `sudo`, and secret-input events.
- Separate durable Dashboard session IDs from attachment-scoped runtime session IDs.
- Reconnect with a newly minted ticket, exponential backoff, and active-session reattachment.
- If a VPS, proxy, or middlebox blocks WebSocket Upgrade, the app falls back to authenticated REST history in read-only mode. It never retries an in-flight prompt over another protocol because that could execute tools twice.
- Hermes 0.19.1 approval events have no request ID, so the client displays and replies to them in strict per-session FIFO order. A complete fix still requires a server-side request ID or command-digest validation.

### Requirements

| Location | Requirement | Notes |
|---|---|---|
| iOS client | iPhone/iPad running iOS 17+ | A physical device requires Apple Development signing and developer trust on the device |
| Build Mac | macOS and Xcode 15.3+ | The project uses Swift 5.10; the latest stable Xcode is recommended |
| Project generation | XcodeGen, optional | The generated `.xcodeproj` is included; regenerate only after changing `project.yml` |
| OpenCode host | OpenCode CLI; contract verified against 1.18.18 | Recheck `GET /doc` after upgrading because the API evolves quickly |
| Hermes host | Hermes Agent 0.19.1 | The launcher defaults to `~/.local/bin/hermes` |
| Remote ingress | `cloudflared` | Quick Tunnels require no Cloudflare account; this network requires `--protocol http2` |

The iOS app has no CocoaPods, Carthage, or third-party Swift Package dependency. DeepSeek Harness is not included in this repository and is not a build dependency.

### Quick start

#### 1. Build the iOS app

The generated Xcode project is already included:

```sh
open OpenCodeMobile.xcodeproj
```

In Xcode:

1. Select the `OpenCodeMobile` target.
2. Choose your Team under **Signing & Capabilities**.
3. Select a simulator or paired iPhone/iPad.
4. Press `⌘R` to build and run.
5. For a first Personal Team installation, trust the Developer App under iPhone Settings → General → VPN & Device Management.

After editing `project.yml`, regenerate the project with:

```sh
xcodegen generate
```

#### 2. Start OpenCode

Install OpenCode and configure its model providers first. Then create a protected launcher configuration:

```sh
mkdir -p "$HOME/opencode-mobile"
chmod 700 "$HOME/opencode-mobile"
```

Put the following in `~/opencode-mobile/server.conf`:

```sh
OPENCODE_SERVER_PASSWORD='replace-with-a-unique-strong-password'
```

Protect the file and start the service:

```sh
chmod 600 "$HOME/opencode-mobile/server.conf"
cd Launcher
chmod +x launcher.sh
./launcher.sh start
./launcher.sh url
```

The launcher runs a loopback OpenCode server and an HTTP/2 Quick Tunnel. Add an `OpenCode` server in the app using the printed URL, username `opencode`, and the configured password.

Quick Tunnel hostnames can change on every restart. Edit the existing server entry when this happens so its stable ID and Keychain record are reused.

```sh
./launcher.sh status
./launcher.sh url
./launcher.sh stop
```

`stop` stops only the public tunnel and leaves `opencode serve` running.

#### 3. Start Hermes

Install Hermes Agent 0.19.1 and verify the default launcher path:

```sh
"$HOME/.local/bin/hermes" --version
```

Create protected credentials and start the independent Hermes tunnel:

```sh
cd Launcher
./launcher.sh init-hermes
./launcher.sh start-hermes
./launcher.sh url-hermes
```

`init-hermes` writes only a scrypt password hash and a random signing secret to `~/opencode-mobile/hermes.conf`; it does not store the original password.

Add a `Hermes` server in the app using the printed URL, the configured username (default `admin`), and the original password entered during initialization.

```sh
./launcher.sh status-hermes
./launcher.sh url-hermes
./launcher.sh stop-hermes
```

Hermes 0.19.1 enables Dashboard Basic Auth only on a non-loopback bind, so the launcher uses `0.0.0.0:9119`. Before publishing a tunnel, it fails closed unless authentication is explicitly enabled, anonymous protected requests return 401/403, and the configuration mode is `600`.

### Using the app

1. Open Server Settings on first launch.
2. Choose OpenCode or Hermes and enter a name, current Tunnel URL, username, and password.
3. Tap `[ test ]`. OpenCode verifies Health; Hermes also requires a successful `gateway.ready`, so REST login alone is not treated as an executable connection.
4. Tap `[ save + connect ]`.
5. Create or resume a session, submit prompts, and use the stop button to interrupt active work.
6. Review and answer approval, clarification, sudo, or secret requests. Sensitive answers use secure entry.
7. Edit the saved URL whenever a Quick Tunnel hostname changes.

OpenCode-only surfaces—projects, providers, models, agents, MCP, and file browsing—are hidden or disabled for Hermes. If Hermes WebSocket connectivity fails, transcript history remains readable, while prompt submission, session mutation, and interactive replies are disabled.

### Technical architecture

The client uses a backend-adapter architecture under a single `@MainActor AppState`. SwiftUI views consume normalized sessions, messages, tools, and interaction requests without directly owning network transports.

| Layer | Main files | Responsibility |
|---|---|---|
| UI | `Views/`, `Theme/` | Native TUI-style chat, session, project, settings, and approval UI |
| Orchestration | `App/AppState.swift` | Backend routing, connection lifecycle, session mapping, reconciliation, and fallback policy |
| OpenCode REST | `API/OpenCodeClient.swift`, `API/OpenCodeAPI.swift` | Long-lived `URLSession`, Basic Auth, directory header/query, endpoint wrappers |
| OpenCode events | `API/EventStream.swift` | Per-directory SSE, 90-second idle timeout, reconnect, foreground reconciliation |
| Hermes REST | `API/HermesClient.swift` | Status probe, login, in-memory cookies, one-time WS ticket, read-only history |
| Hermes live gateway | `API/HermesGatewaySocket.swift` | Actor-isolated WebSocket, JSON-RPC, timeouts, ping, typed operations |
| Protocol models | `Models/` | Lenient Codable/JSON values, version-skew tolerance, durable/runtime ID separation |
| Credentials | `API/KeychainStore.swift` | Keychain password storage and redacted UserDefaults metadata |
| Host launcher | `Launcher/launcher.sh` | Separate services/tunnels, changing URLs, fail-closed authentication checks |

#### Transport matrix

| Backend | Authentication | History/config | Live control | Failure behavior |
|---|---|---|---|---|
| OpenCode on a normal HTTPS host | HTTP Basic | REST | One SSE stream per active directory | Reconnect after silence and reconcile over REST |
| OpenCode over Quick Tunnel | HTTP Basic | REST | Quick Tunnel buffers SSE | Direct adaptive REST polling at 0.75–4 second intervals |
| Hermes | Password login + HttpOnly cookie + one-time ticket | Dashboard REST | `/api/ws` WSS JSON-RPC | Exponential reconnect; read-only fallback; no prompt replay |

Key invariants:

- OpenCode `/event` is directory-instance scoped rather than global; changing projects must change `x-opencode-directory`.
- Network clients are long-lived to reuse DNS, TCP, TLS, and HTTP/2 state.
- OpenCode deltas are coalesced by message part before SwiftUI publication to reduce main-thread churn.
- Foregrounding always reconnects and reconciles against REST; the app never assumes an iOS background transport survived.
- A Hermes prompt with uncertain WebSocket delivery is reported to the user and is never automatically resent.
- Protocol models tolerate unknown fields and events, but server upgrades still require protocol regression tests.

### Testing

The `OpenCodeMobileTests` target covers transport selection, legacy configuration migration, password non-persistence, OpenCode directory routing, Hermes authentication/cookie/ticket behavior, lenient decoding, durable/runtime session IDs, approval FIFO, and credential-redacted errors.

Use the simulator or physical-device `xcodebuild test` examples in the Chinese section above, replacing the simulator name, device UDID, and Team ID with local values. A first-time physical device must trust the Developer App certificate before Xcode can launch the test runner.

### Known limitations

1. Cloudflare Quick Tunnel hostnames are not stable; update the saved App URL after a restart.
2. OpenCode Quick Tunnels buffer SSE. REST polling can recover output and completion, but it cannot discover `permission.asked`; approval-dependent tasks may stall.
3. Hermes mutations require WebSocket. If a VPS or proxy blocks Upgrade, only authenticated REST history is available.
4. Hermes 0.19.1 approval events have no request ID. FIFO reduces mismatch risk but cannot eliminate ambiguity after a silent server-side timeout.
5. Both upstream protocols evolve quickly. The current integration baselines are OpenCode 1.18.18 and Hermes 0.19.1.
6. DeepSeek Harness has no Swift adapter, authentication mapping, or live-event integration yet, cannot be selected as an App backend, and is not included in this repository.

---

## 仓库状态与许可证 / Repository status and licensing

本仓库目前没有 `LICENSE` 文件，因此不要默认 OpenCodeMobile 具有某种开源授权。正式公开发布前，应由仓库所有者选择并添加明确的许可证与第三方归属说明。

This repository currently has no `LICENSE`, so no open-source grant should be assumed for OpenCodeMobile. Before public distribution, the repository owner should choose and add an explicit license and third-party attribution notice.
