<!-- source: template/dim-deploy -->
### 部署

- Dockerfile: {{HAS_DOCKERFILE}}
- Kubernetes: {{HAS_K8S}}
- CI/CD: {{CI_PIPELINE}}
- 基础设施即代码 (Terraform): {{HAS_TERRAFORM}}

部署原则:
- 真实生产凭据不入仓库, 由本地 `.local.*` 文件维护.
- 默认配置指向测试/本地环境.
<!-- /source: template/dim-deploy -->
