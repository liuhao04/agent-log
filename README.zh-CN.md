# AgentLog

[English](README.md)

AgentLog 是一个原生 macOS 应用，用来浏览本机的 Codex CLI 和 Claude Code
会话日志。

AgentLog 会读取本机 Codex CLI 和 Claude Code 历史记录，按项目组织会话，并把
每个 session 展示为干净的 query/response transcript。它适合频繁使用 coding
agent、需要快速回看项目上下文和历史讨论的人。

## 为什么用 AgentLog

- **本地优先，重视隐私。** AgentLog 只读取你 Mac 上的本地文件，不上传日志、
  不做远端同步，也不加入遥测。coding agent transcript 往往包含项目路径、
  代码片段、研究想法、账号上下文和调试细节，这个边界很重要。
- **一个原生 macOS 应用同时支持 Codex CLI 和 Claude Code。** 很多日志查看器
  只支持单一 agent。AgentLog 把 Codex 和 Claude 会话统一到同一套
  project/session/conversation 模型里。
- **以项目为中心浏览。** 左侧是项目，中间是 session，右侧是可读 conversation，
  更符合开发工作流，而不是把所有历史记录混在一个全局列表里。
- **干净的 query/response 阅读体验。** AgentLog 不直接 dump 原始 JSONL 事件，
  而是按用户 query 分组，支持展开/折叠，让阅读重点回到对话本身。
- **全局本地搜索。** 本地 SQLite 搜索索引支持跨 Codex 和 Claude session 搜索，
  可以按来源或项目过滤，并跳回命中的 query 或 response。
- **小而可审计，目标明确。** AgentLog 是专注的本地历史阅读器，不是 agent 运行
  平台、云 dashboard 或分析系统。代码就在这个仓库里，数据访问行为可以审计。

## 功能

- 按项目浏览 Codex CLI 和 Claude Code session。
- 查看清理后的 conversation，隐藏 tool call、token event 和内部记录。
- 按用户 query 折叠和展开会话，默认折叠。
- 跨项目和 session 搜索，并跳转到高亮命中位置。
- 按来源和项目过滤跨项目搜索结果。
- 在窗口 header 和菜单栏中查看当前运行版本。
- 从菜单栏图标重启或重新打开应用。
- 在 Finder 中 reveal 当前选中的项目。
- 将当前 clean conversation 复制或导出为 Markdown。
- 只读取本地数据。

## 数据来源

AgentLog 读取本机 Codex CLI 数据：

- `~/.codex/state_5.sqlite`：项目和 session 索引。
- `~/.codex/sessions/**/rollout-*.jsonl`：conversation 事件。

它也读取 Claude Code session 日志：

- `~/.claude/projects/**/*.jsonl`：项目 session 事件。

当前 parser 默认只保留用户消息和 assistant 文本。Tool call、thinking block、
file-history event 和 Claude subagent log 默认会被跳过。Codex CLI 和 Claude Code
的本地存储格式都属于内部格式，未来版本可能变化。

## 环境要求

- macOS 14 或更新版本
- Xcode 26 或更新版本，或兼容的 Xcode toolchain
- 本机已有 `~/.codex` 下的 Codex CLI session，或 `~/.claude` 下的 Claude Code
  session

## 安装

```bash
Scripts/install-app.sh
```

这个脚本会构建应用、安装到 `/Applications/AgentLog.app`，并打开应用。

## 只构建不安装

```bash
xcodebuild -project AgentLogApp.xcodeproj -scheme "AgentLog" -configuration Debug -destination 'platform=macOS' build
```

也可以用 Xcode 打开 `AgentLogApp.xcodeproj`，运行 `AgentLog` scheme。

## App 图标

应用图标由确定性的 AppKit 绘制脚本生成：

```bash
swift Scripts/generate-app-icon.swift
```

生成的 PNG 文件位于 `App/Assets.xcassets/AppIcon.appiconset`。

## 隐私

AgentLog 是 local-first 工具，不会把你的 conversation log 发送到任何服务器。
详情见 [PRIVACY.md](PRIVACY.md)。

## Sandbox 说明

当前 Xcode app target 关闭了 App Sandbox，以便直接读取 `~/.codex` 和
`~/.claude`。如果未来要广泛分发签名版本，应改成用户授权文件夹访问流程。

## 项目状态

这是一个早期 macOS prototype。核心工作流已经可用，但数据格式基于当前
Codex CLI 和 Claude Code 的本地存储，应视为 best-effort 支持。

## License

MIT. See [LICENSE](LICENSE).
