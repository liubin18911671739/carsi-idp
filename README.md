# CARSI / Shibboleth IdP 部署资料

本仓库保存 CARSI/Shibboleth IdP 5.2.2 的 Docker 部署配置、凭据生成脚本和中文操作手册。仓库中的示例域名和口令仅供本地测试；它们不代表已接入 CARSI 联邦，也不能直接用于生产环境。

## 内容

- `docker-compose.yml`：IdP、Nginx 反向代理和 MariaDB 服务定义。
- `nginx/conf.d/idp.conf`：HTTPS 反向代理示例，证书从本机 `nginx/certs/` 挂载。
- `scripts/gen-credentials.sh`：调用 Shibboleth IdP 镜像生成签名、加密和 sealer 凭据。
- `.env.example`：环境变量模板。复制为本地 `.env` 后修改；`.env`、凭据和运行数据已列入 `.gitignore`。
- `CARSI_IDP/`：华为云 ECS 部署手册，以及模拟部署与升级运维说明。
- `build_huawei_ecs_guide.py`、`build_deployment_summary.py`：上述 DOCX 的生成脚本。
- `_archive_pre_unicon/`：早期自建镜像方案的归档材料，不是当前 Compose 配置所引用的构建目录。

## 部署前准备

当前 Compose 配置需要部署者自行准备证书、定制配置和数据库初始化脚本。首次启动前，确认以下挂载源目录和文件已按本校环境配置好：

- `customized/`：IdP 定制配置。
- `nginx/certs/idp.crt` 与 `nginx/certs/idp.key`：Nginx 使用的 TLS 证书和私钥。
- `mariadb-init/`：需要时放入数据库初始化 SQL。

还需确认主机 80、443 端口可用，DNS 已指向部署主机，并准备与主机名、证书及 EntityID 一致的域名。不要把私钥、口令、真实用户数据或运行时数据库加入 Git。

## 本地配置与启动

以下步骤展示配置流程，不构成生产上线验收：

```sh
cp .env.example .env
chmod 600 .env
```

编辑 `.env`：将测试域名替换为实际环境值，并为所有口令和 `PERSISTENT_ID_SALT` 设置独立的强随机值。持久化 ID salt 和生成的凭据必须安全备份；丢失或重建可能导致已发放的持久化标识变化，或需要与服务提供方重新交换元数据。

准备前述挂载目录和文件后，执行：

```sh
./scripts/gen-credentials.sh
docker compose config
docker compose up -d
docker compose ps
docker compose logs -f idp
```

脚本检测到已有签名和加密证书时会跳过生成。不要为了“重试”而删除或覆盖 `credentials/`。启动后可从部署主机检查入口：

```sh
curl -I https://<你的IdP域名>/idp/shibboleth
```

请继续按手册验证 IdP 元数据、TLS 证书、属性释放、持久化 ID、备份恢复和服务提供方对接。容器启动或单个 HTTP 端点返回成功，都不能单独证明联邦接入已完成。

## 凭据与数据保护

不要提交 `.env`、`credentials/`、TLS 私钥、`mariadb-data/`、日志、元数据或机构真实数据。本 Compose 使用绑定目录保存关键数据；停止容器不会替代备份，删除这些本地目录仍会造成数据丢失。备份前请核对 `credentials/`、数据库和元数据的恢复步骤。

## 操作手册

- [华为云 ECS 部署实施手册](CARSI_IDP/CARSI_IdP_华为云ECS部署实施手册.docx)
- [模拟部署与升级运维说明](CARSI_IDP/CARSI_IdP_模拟部署与升级运维说明.docx)
