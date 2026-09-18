# GhostApp

GhostApp 是面向 macOS 非 `.app` 软件的安全扫描和深度卸载 CLI。它从包管理器、PATH、用户级二进制目录、关联数据目录、LaunchAgent 和 Shell 配置出发，建立可供人和 AI 使用的软件资产清单。

> 当前版本是 `0.1.0` MVP。删除默认只生成计划；关联数据移入废纸篓，不做永久删除。

## 为什么需要它

终端工具通常不会出现在“应用程序”目录中。Homebrew Formula/Cask、`curl | bash` 安装器、Cargo、npm、pipx、uv 等可能同时留下：

- 可执行文件和符号链接；
- `~/.config`、`~/.cache`、`~/.local/share` 和专用隐藏目录；
- 登录凭据、会话记录和日志；
- LaunchAgent/LaunchDaemon；
- Shell PATH 修改。

只删除可执行文件会留下关联数据。GhostApp 将这些对象合并成一份带证据、可信度和敏感性标记的清单。

## 已实现

- Homebrew Formula 和 Cask 扫描；
- Cargo、npm、pipx、uv 全局工具扫描；
- `~/.local/bin`、`~/bin`、`~/.grok/bin`、`~/.cargo/bin`、`~/go/bin` 手工二进制扫描；
- 约定目录关联：`~/.config`、`~/.cache`、`~/.local/share`、`~/Library/*`；
- 内置 Grok Build 深度关联规则；
- 用户和系统 LaunchAgent/LaunchDaemon 关联；
- Shell 配置引用检测；
- 稳定的 JSON 输出和退出码；
- `program`、`cache`、`full` 三档卸载计划；
- 敏感数据默认保护；
- 显式确认后调用原包管理器，并将用户数据移入废纸篓。

## 构建

要求 macOS 13+ 和 Swift 6：

```bash
swift build -c release
swift test
```

安装到用户目录：

```bash
install -m 755 .build/release/ghostapp ~/.local/bin/ghostapp
```

## 使用

```bash
# 人类可读清单
ghostapp scan

# AI/脚本使用的稳定 JSON
ghostapp scan --compact

# 查看软件及关联数据
ghostapp inspect grok-build

# 预览“程序 + 缓存”清理
ghostapp plan grok-build --mode cache

# 完整计划，但仍保护凭据和会话
ghostapp plan grok-build --mode full --json

# 连敏感凭据和会话一起纳入完整计划
ghostapp plan grok-build --mode full --include-sensitive

# remove 默认仍是 dry-run
ghostapp remove grok-build --mode full

# 真正执行；必须同时提供两个显式标志
ghostapp remove grok-build --mode full --execute --yes
```

## AI 调用约定

推荐使用 `--compact` 获取单行 JSON。AI 应先调用 `scan` 或 `inspect`，再调用 `plan`，向用户展示所有动作；未经用户明确授权，不应添加 `--execute --yes`。

退出码：

| Code | 含义 |
|---:|---|
| `0` | 成功 |
| `2` | 参数错误 |
| `3` | 未找到软件 |
| `4` | 匹配不唯一 |
| `10` | 执行阶段至少一个动作失败 |

完整契约见 [docs/AI_INTEGRATION.md](docs/AI_INTEGRATION.md)。开发路线见 [docs/DEVELOPMENT_PLAN.md](docs/DEVELOPMENT_PLAN.md)。

## 安全模型

- 扫描阶段不需要管理员权限；
- 不读取凭据、会话和用户文件内容，只读取路径和元数据；
- 包管理器软件通过原包管理器卸载；
- 用户目录残留移入废纸篓；
- 系统级残留和 Shell 配置默认只提示人工检查；
- `--include-sensitive` 与真正执行是两个独立授权；
- 任意来源脚本都可能写入未知路径，因此已有软件的关联结果是尽力而为，而非绝对完整。

## License

MIT
