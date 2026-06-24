# Changelog

## Unreleased

### Breaking Changes
- `gdcli exec` 默认输出格式从原始 minified JSON 改为 **TOON**。脚本场景请添加 `--json` 标志恢复旧行为。

### Features
- `gdcli exec` 支持 TOON 输出，自动根据响应数据结构选择表格/键值/树状形态
- 新增 `cli/src/format/` 模块，对外暴露 `render_exec_body` API
