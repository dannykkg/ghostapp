# GhostApp 开发方案

## 1. 产品目标

GhostApp 是一个 macOS CLI 软件资产扫描与深度卸载工具，重点覆盖不以 `.app` 形式存在的软件。它必须同时适合人类交互和 AI/自动化调用。

核心目标：

1. 发现包管理器、安装脚本和用户目录中的 CLI 软件；
2. 将程序与配置、缓存、日志、会话、凭据、后台服务关联；
3. 为每个关联结果提供证据和可信度；
4. 优先调用原安装来源的卸载方式；
5. 在安全边界内清理残留，并提供机器可读结果。

非目标：

- 不替代传统 `.app` 卸载器；
- 不根据名称相似度自动删除目录；
- 不承诺事后完整还原任意安装脚本的全部行为；
- 不绕过 SIP、TCC 或包管理器的所有权模型。

## 2. 用户接口

```text
scan                  建立完整资产清单
list                  scan 的别名
inspect <query>       查看单个软件及关联证据
plan <query>          生成卸载计划
remove <query>        默认 dry-run；显式授权后执行
doctor                检查本机可用 Provider
```

所有读取命令支持 `--json`、`--compact` 和 `--output`。JSON 包含固定 `schemaVersion`，用于 AI 和脚本兼容。

## 3. 架构

### 3.1 Provider 层

Provider 负责从可信来源生成 `PackageRecord`：

- Homebrew Formula/Cask；
- Cargo；
- npm；
- pipx；
- uv；
- 常见用户级 bin 目录。

每条记录包含来源、版本、二进制、安装根目录和原生卸载命令。

### 3.2 Association 层

关联引擎使用三类证据：

1. 明确规则：软件已知数据路径，可信度 `certain`；
2. 系统关系：符号链接、LaunchAgent Program、包管理器清单；
3. 约定路径：规范化软件名与 XDG/macOS 标准目录精确匹配，可信度 `medium`。

第一版规则保存在只读 JSON 资源中。未来支持用户规则目录和签名社区规则仓库。

### 3.3 Plan/Execute 层

卸载模式：

- `program`：仅程序；
- `cache`：程序、缓存和日志；
- `full`：程序和所有已确认关联数据。

凭据、会话及推测为用户状态的数据带 `sensitive` 标记，即使 `full` 也默认排除，必须添加 `--include-sensitive`。

真正执行需要 `--execute --yes`。只有 `certain` 和 `high` 可信度关联可自动执行，`medium` 和 `low` 只进入人工检查。用户文件只移动到按时间戳隔离的废纸篓目录。

## 4. 威胁模型

- 恶意目录名不能让扫描器越过用户主目录；
- 符号链接在归属判断中解析；删除前同时验证词法路径、父目录真实路径和最终对象类型；
- 卸载命令只允许内部 Provider 生成、且位于受信任安装根目录的可执行程序；
- `/`、主目录和主要用户内容目录永不作为删除目标；
- 系统级残留默认只展示；
- Shell 配置只报告引用行，不自动重写整个文件；
- 不读取或输出凭据内容。
- 外部卸载命令失败后停止关联数据清理；命令执行带超时和输出读取上限。

## 5. 版本路线

### v0.1.1 — 可运行 MVP（本仓库当前状态）

- Swift 原生单文件可执行产物；
- Homebrew、Cargo、npm、pipx、uv、手工二进制 Provider；
- 数据目录、launchd、Shell 配置关联；
- Grok Build 规则；
- JSON/退出码契约；
- 安全计划和可恢复执行；
- 路径、置信度、命令信任、失败停止和 Provider fixture 单元测试与 GitHub Actions。

### v0.2 — 覆盖更多安装体系

- Apple PKG 收据（只读文件归属，不把 `pkgutil --forget` 当卸载）；
- MacPorts、Nix、Conda/Mamba、mise/asdf/rustup、Go、RubyGems；
- Homebrew JSON 元数据及 Cask `zap` 关联；
- 用户规则与规则校验命令；
- 扫描缓存和增量扫描。

### v0.3 — 安装追踪

- 首次基线快照；
- FSEvents 增量变更记录；
- 安装前后差异归属；
- 软件运行期间写入目录观察；
- 可导出、可审计的安装账本。

### v0.4 — 生产化

- 签名与公证发布；
- Homebrew Formula；
- JSON Schema 和兼容性测试；
- 社区规则仓库和供应链签名；
- 性能、权限和路径模糊测试；
- 可选的最小权限 privileged helper，用于经确认的系统级卸载。

## 6. 验收标准

- 在纯 CLI Grok Build 官方安装和 Homebrew 安装下均能识别程序；
- 能区分缓存、配置、凭据和会话；
- 默认计划不包含敏感数据；
- 未同时提供 `--execute --yes` 时不改变文件系统；
- 所有用户数据删除均可从废纸篓恢复；
- JSON 输出在相同系统状态下字段稳定、顺序确定；
- 单元测试覆盖规则关联、敏感数据保护和 Trash 执行。
