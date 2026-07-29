<!-- source: template/dim-code -->
### 代码质量红线

- **[强制] 禁止跳过 review**: 禁止绕过代码审查直接合并主干分支.
- **[强制] 测试覆盖**: 关键业务路径必须有测试覆盖; 修改现有代码后必须运行相关测试套件.
- **[默认] 静态检查**: 提交前应通过 lint, 格式化检查和静态分析.
- **[默认] 依赖审计**: 引入新依赖前应评估许可证, 安全性和维护状态.

#### 语言专属编码规范

{{LANGUAGE_CODE_STANDARDS}}

{{USER_REDLINES_CODE}}
<!-- /source: template/dim-code -->
