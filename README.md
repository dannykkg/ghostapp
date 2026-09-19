# GhostApp

面向 macOS 的非 `.app` 软件资产扫描与安全卸载 CLI。

GhostApp 用来发现那些不会出现在“应用程序”目录里的工具：Homebrew Formula、全局 npm/Cargo/pipx/uv 工具、通过安装脚本写入用户目录的二进制，以及它们留下的配置、缓存、日志、会话和后台服务。

> 当前版本：`0.2.0`。默认只生成清理计划；执行时，关联的用户文件会移动到废纸篓，并记录可撤销事务。

## 为什么做 GhostApp

很多 macOS 工具通过终端安装：

```bash
brew install ...
npm install -g ...
cargo install ...
curl ... | sh
```

它们可能同时写入：

- PATH 中的可执行文件或符号链接；
- `~/.config`、`~/.cache`、`~/.local/share` 和软件专用隐藏目录；
- 凭据、会话、下载内容和日志；
- LaunchAgent 或 LaunchDaemon；
- `.zshrc`、`.zprofile` 等 Shell 配置。

只删除一个可执行文件通常不等于完整卸载。GhostApp 把程序与关联数据整理为一份带来源证据、可信度和敏感性标记的清单，再生成可审查的卸载计划。

## 当前能力

| 能力 | 状态 |
|---|---|
| Homebrew Formula/Cask | 已支持 |
| Cargo、npm、pipx、uv 全局工具 | 已支持 |
| Rustup 工具链与 shim 聚合 | 已支持 |
| 常见用户级 `bin` 目录 | 已支持 |
| XDG 与 macOS 常见数据目录 | 已支持；约定路径标记为中等可信度，只进入人工检查 |
| LaunchAgent/LaunchDaemon 关联 | 已支持扫描；系统级项目默认仅提示 |
| Shell PATH 引用 | 已支持检测；默认不自动改写配置文件 |
| 已知软件深度规则 | 已支持，当前内置 Grok Build、Google Antigravity CLI 规则 |
| Homebrew 顶层/依赖分类 | 已支持 |
| 重复命令与 PATH 生效版本 | 已支持 |
| 断链、失效 PATH、未归属/孤儿 launchd 项 | 已支持，只报告不自动清理 |
| 冻结计划、过期检测与执行后验证 | 已支持 |
| 事务历史与 Trash 文件恢复 | 已支持；不反向执行包管理器命令 |
| JSON/AI 接口 | 已支持 |
| 传统 `.app` 深度卸载 | 暂不支持 |
| 恶意软件检测 | 不属于本项目范围 |

GhostApp 是软件资产和残留清理工具，不是杀毒软件。扫描结果是基于可解释证据的尽力判断，不应把低可信度名称匹配当成确定归属。

## 安装

要求：

- macOS 13 或更高版本；
- Swift 6 工具链。

从源码构建并安装到当前用户目录：

```bash
git clone https://github.com/dannykkg/ghostapp.git
cd ghostapp
swift build -c release
install -d ~/.local/bin
install -m 755 .build/release/ghostapp ~/.local/bin/ghostapp
```

确保 `~/.local/bin` 已加入 `PATH`，然后检查运行环境：

```bash
ghostapp doctor
ghostapp version
```

## 快速开始

### 1. 建立软件清单

```bash
ghostapp scan
```

`list` 是 `scan` 的别名：

```bash
ghostapp list
```

单独查看同名命令的多份安装以及当前由 `PATH` 选中的版本：

```bash
ghostapp duplicates
```

### 2. 查看一个软件及其关联数据

```bash
ghostapp inspect grok-build
```

查询可以使用名称、显示名称或完整 Package ID。匹配不唯一时，GhostApp 会拒绝继续并列出候选项。

### 3. 预览卸载计划

```bash
ghostapp plan grok-build --mode full
```

卸载模式：

| 模式 | 包含内容 |
|---|---|
| `program` | 只卸载程序 |
| `cache` | 程序、缓存和日志 |
| `full` | 程序及检测到的关联数据；敏感数据仍默认排除 |

需要把凭据、会话和潜在用户状态纳入计划时，必须显式添加：

```bash
ghostapp plan grok-build --mode full --include-sensitive
```

### 4. 执行清理

`remove` 默认仍然是 dry-run：

```bash
ghostapp remove grok-build --mode full
```

只有同时提供 `--execute --yes` 才会真正执行：

```bash
ghostapp remove grok-build \
  --mode full \
  --include-sensitive \
  --execute --yes
```

对于包管理器安装的软件，GhostApp 优先调用原包管理器的卸载命令。对于安全范围内的用户目录残留，则移动到按时间戳隔离的废纸篓目录。

需要把“审查”和“执行”严格绑定到同一份计划时，可生成冻结计划并稍后应用：

```bash
ghostapp plan grok-build --mode full --output plan.json
ghostapp apply plan.json                 # 只验证并预览
ghostapp apply plan.json --execute --yes # 执行完全相同的计划
```

`apply` 会检查计划 SHA-256 和目标文件身份；计划被修改或目标在审查后发生变化时会拒绝执行。执行后可查看事务，并恢复被移动到废纸篓的文件：

```bash
ghostapp history
ghostapp undo <transaction-id>                 # 只预览
ghostapp undo <transaction-id> --execute --yes # 恢复文件
```

`undo` 不会自动重新安装已经由 Homebrew/npm/Cargo 等卸载的程序。

## AI 与自动化

所有读取流程都支持 JSON 输出：

```bash
ghostapp scan --compact
ghostapp inspect grok-build --compact
ghostapp plan grok-build --mode full --compact
```

也可以写入文件：

```bash
ghostapp scan --output inventory.json
```

推荐的 AI 调用顺序：

```text
scan / inspect → plan --output → 向用户展示计划 → 获得明确授权 → apply
```

自动化程序不应根据 JSON 中的路径自行拼接 `rm`，而应让 GhostApp 执行清理并重新校验命令与路径。完整字段和安全约定见 [AI Integration Contract](docs/AI_INTEGRATION.md)。

退出码：

| Code | 含义 |
|---:|---|
| `0` | 成功 |
| `2` | 参数或用法错误 |
| `3` | 没有找到匹配软件 |
| `4` | 匹配不唯一 |
| `10` | 执行阶段至少有一个动作失败 |

## 安全模型

- 扫描阶段不需要管理员权限；
- 不读取或输出凭据、会话等文件的正文；
- 删除默认是 dry-run；
- 敏感数据需要独立的 `--include-sensitive` 授权；
- 真正执行必须同时使用 `--execute --yes`；
- 用户数据移入废纸篓，不执行递归永久删除；
- 系统级文件和 Shell 配置默认只进入人工检查；
- 包管理器卸载命令来自内部 Provider；其可执行文件必须来自受信任的系统或用户级安装根目录；
- 所有自动移动路径都必须通过父目录软链接解析和用户目录边界校验；
- 中、低可信度关联不会自动删除；
- 包管理器或 `launchctl` 失败后停止后续关联数据清理；
- 包管理器卸载返回成功后验证已发现的可执行文件确实消失，否则停止清理关联数据；
- 冻结计划带内容哈希和文件身份前置条件，防止审查后被替换；
- 每次真实执行写入事务清单，Trash 移动可通过 `undo` 恢复；
- 外部命令带超时，并限制读取到执行报告中的输出大小。

安全问题与隐私注意事项见 [SECURITY.md](SECURITY.md)。公开 Issue 中请勿粘贴 Token、会话正文、未脱敏的主目录路径或完整扫描 JSON。

## 已知限制

- 无法保证还原任意第三方安装脚本曾经写入的所有路径；
- 通用目录关联依赖精确名称约定，可能出现漏报；
- 系统级卸载仍需要人工审查和管理员授权；
- `remove` 仍会即时重新扫描；需要严格执行已审查内容时应使用 `plan --output` 与 `apply`；
- `undo` 只恢复 GhostApp 移入废纸篓的文件，无法通用地反转第三方包管理器命令；
- `inspect` 的 JSON 当前直接返回 `PackageRecord`，尚未使用统一的顶级 envelope；
- 暂不追踪安装前后的文件系统变化；
- 当前 Release 仅提供未签名的 Apple Silicon 构建；尚无公证、Universal Binary 或 Homebrew Formula。

## 开发

```bash
swift build
swift test
swift build -c release
```

核心目录：

```text
Sources/GhostApp/             CLI 参数与人类可读输出
Sources/GhostAppCore/         扫描、关联、计划和执行逻辑
Sources/GhostAppCore/Resources/rules.json
                              已知软件关联规则
Tests/GhostAppCoreTests/      核心安全行为测试
```

开发路线与设计取舍见 [开发方案](docs/DEVELOPMENT_PLAN.md)。

## 贡献

欢迎提交 Issue 和 Pull Request，尤其是：

- 新的包管理器 Provider；
- 可验证的软件数据目录规则；
- 路径安全、符号链接和权限边界测试；
- JSON Schema 与兼容性测试；
- 文档和真实环境中的漏报案例。

新增清理规则时，请提供关联证据，并把凭据、会话或用户状态正确标记为敏感数据。

## License

[MIT](LICENSE) © 2026 Danny KKG
