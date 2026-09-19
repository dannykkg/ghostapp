# AI Integration Contract

GhostApp 为 AI 和自动化提供非交互式、可组合的 JSON 接口。

## 推荐调用序列

```bash
ghostapp scan --compact
ghostapp inspect homebrew-cask:grok-build --compact
ghostapp plan homebrew-cask:grok-build --mode full --output plan.json
```

AI 必须先向用户展示计划，再请求执行授权。只有得到明确授权后才可以调用：

```bash
ghostapp apply plan.json --execute --yes --compact
```

`plan` 输出包含不可变 `planID`、内容 `planHash` 和目标文件身份前置条件。`apply` 在执行前验证哈希与前置条件；内容被修改、命令被替换或目标状态改变时返回失败。`remove` 是方便人类即时操作的“重新扫描并执行”入口；AI 应优先使用冻结计划。

敏感数据需要单独授权：

```bash
ghostapp plan homebrew-cask:grok-build \
  --mode full --include-sensitive --output plan.json
ghostapp apply plan.json --execute --yes --compact
```

## 稳定字段

`scan`、`plan`、`remove`、`apply`、`history`、`undo` 和 `doctor` 的顶级 JSON 对象包含 `schemaVersion`。`inspect` 当前直接返回 `PackageRecord`，尚未使用统一 envelope。Inventory 的核心字段：

```json
{
  "schemaVersion": "1.3",
  "generatedAt": "2026-09-18T00:00:00Z",
  "host": "MacBook",
  "packages": [],
  "warnings": [],
  "findings": [],
  "duplicateProducts": [],
  "assessment": {
    "status": "healthy",
    "statistics": {},
    "counts": {},
    "items": []
  }
}
```

Package ID 格式为 `<manager>:<name>`。手工安装的软件可能包含扫描根路径，以避免同名二进制冲突。

Artifact 的关键语义：

- `confidence`: `certain | high | medium | low`；
- `sensitive`: 是否包含凭据、会话或潜在用户状态；
- `removable`: GhostApp 是否允许自动移入废纸篓；
- `evidence`: 关联来源和可解释说明。

`directInstall` 为 `true` 表示显式安装，为 `false` 表示依赖，为 `null` 表示当前 Provider 无法可靠分类。`findings` 是断链、失效 PATH 或未归属 launchd 项等独立问题；它们不会自动转成删除动作。

`assessment` 是 GhostApp 本地规则生成的结论，不依赖 AI：

- `status`: `healthy | needs-review | warning | danger`；
- `items[].level`: `info | review | warning | orphaned | dangerous`；
- `items[].summary` 是适合人类显示的短说明，`detail` 和 `path` 保留完整机器证据；
- `review` 只表示需要人工确认，不能描述成确定异常；
- macOS Cryptex 等动态系统 PATH 项降级为 `info`，避免自动化误报。

## 自动化安全规则

1. 不把 `medium` 或 `low` 可信度结果描述成确定事实；
2. `medium` 或 `low` 可信度关联只会生成 `manual-review`，不能描述为自动清理项；
3. 默认不传 `--include-sensitive`；
4. 用户要求“扫描、检查、分析”不构成执行卸载授权；
5. `manual-review` 动作不能被视为已经完成；
6. dry-run 的动作位于 `planned`，`completed` 为空，不能描述成已经清理；
7. `failed` 非空或退出码为 `10` 时，必须报告失败；外部卸载命令失败时，后续关联数据不会继续清理；
8. 不直接复刻 JSON 中的路径执行 `rm`，应让 GhostApp 负责路径和命令校验。
9. 优先把 `plan` 保存到文件并用 `apply` 执行；不要根据扫描结果重新构造动作。
10. 保存真实执行返回的 `transactionID`。`undo` 只能恢复 Trash 文件移动，不能描述为重新安装包管理器软件。
11. 优先采用 `assessment.status` 和 `assessment.items`；AI 可以补充解释，但不应把 `review` 擅自升级为异常。
