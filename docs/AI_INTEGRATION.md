# AI Integration Contract

GhostApp 为 AI 和自动化提供非交互式、可组合的 JSON 接口。

## 推荐调用序列

```bash
ghostapp scan --compact
ghostapp inspect homebrew-cask:grok-build --compact
ghostapp plan homebrew-cask:grok-build --mode full --compact
```

AI 必须先向用户展示计划，再请求执行授权。只有得到明确授权后才可以调用：

```bash
ghostapp remove homebrew-cask:grok-build --mode full --execute --yes --compact
```

敏感数据需要单独授权：

```bash
ghostapp remove homebrew-cask:grok-build \
  --mode full --include-sensitive --execute --yes --compact
```

## 稳定字段

所有顶级 JSON 对象包含 `schemaVersion`。Inventory 的核心字段：

```json
{
  "schemaVersion": "1.0",
  "generatedAt": "2026-09-18T00:00:00Z",
  "host": "MacBook",
  "packages": [],
  "warnings": []
}
```

Package ID 格式为 `<manager>:<name>`。手工安装的软件可能包含扫描根路径，以避免同名二进制冲突。

Artifact 的关键语义：

- `confidence`: `certain | high | medium | low`；
- `sensitive`: 是否包含凭据、会话或潜在用户状态；
- `removable`: GhostApp 是否允许自动移入废纸篓；
- `evidence`: 关联来源和可解释说明。

## 自动化安全规则

1. 不把 `medium` 或 `low` 可信度结果描述成确定事实；
2. 默认不传 `--include-sensitive`；
3. 用户要求“扫描、检查、分析”不构成执行卸载授权；
4. `manual-review` 动作不能被视为已经完成；
5. dry-run 的动作位于 `planned`，`completed` 为空，不能描述成已经清理；
6. `failed` 非空或退出码为 `10` 时，必须报告部分失败；
7. 不直接复刻 JSON 中的路径执行 `rm`，应让 GhostApp 执行既定计划。
