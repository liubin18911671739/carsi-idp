#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# CARSI IdP container entrypoint
#   1. 校验必需的环境变量
#   2. 首次启动：若 credentials/ 为空 → 执行 IdP 官方 installer 初始化
#      （生成 idp-signing / idp-encryption / sealer 凭据与 idp-metadata.xml）
#   3. 同步 conf/ 模板 → 渲染 idp.properties 中的占位符
#   4. 建 war（或直接部署 edit-webapp）→ 交给 Jetty 启动
#
#   幂等：credentials 已存在则跳过 installer，绝不重新生成密钥
#   （重新生成等于所有已对接 SP 需要重新交换 metadata）
# ─────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

IDP_HOME="${IDP_HOME:-/opt/shibboleth-idp}"
JETTY_BASE="${JETTY_BASE:-/opt/jetty-base}"
JETTY_HOME="${JETTY_HOME:-/opt/jetty}"
IDP_DIST="${IDP_DIST:-/opt/idp-dist}"
RUN_USER="${RUN_USER:-jetty}"

log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint][FATAL] %s\n' "$*" >&2; exit 1; }

# ── 1. 必需变量 ────────────────────────────────────────────────────
: "${ENTITY_ID:?ENTITY_ID is required (e.g. https://idp.example.edu.cn/idp/shibboleth)}"
: "${IDP_HOST:?IDP_HOST is required (e.g. idp.example.edu.cn)}"
: "${IDP_SCOPE:?IDP_SCOPE is required (e.g. example.edu.cn)}"
: "${SEALER_PASSWORD:?SEALER_PASSWORD is required}"
DB_HOST="${DB_HOST:-mariadb}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-shibboleth}"
DB_USER="${DB_USER:-shibboleth}"
DB_PASSWORD="${DB_PASSWORD:?DB_PASSWORD is required}"

log "EntityID = ${ENTITY_ID}"
log "Host     = ${IDP_HOST} / scope = ${IDP_SCOPE}"

# ── 2. 渲染配置（占位符替换）──────────────────────────────────────
render() {
  local src="$1" dst="$2"
  sed -e "s|@@ENTITY_ID@@|${ENTITY_ID}|g" \
      -e "s|@@IDP_HOST@@|${IDP_HOST}|g" \
      -e "s|@@IDP_SCOPE@@|${IDP_SCOPE}|g" \
      -e "s|@@DB_HOST@@|${DB_HOST}|g" \
      -e "s|@@DB_PORT@@|${DB_PORT}|g" \
      -e "s|@@DB_NAME@@|${DB_NAME}|g" \
      -e "s|@@DB_USER@@|${DB_USER}|g" \
      "$src" > "$dst"
}

mkdir -p "${IDP_HOME}"/{conf,credentials,metadata,logs,war}

# conf/ 以镜像模板为基准，保留卷中已有文件（用户本地改动优先）
if [ ! -f "${IDP_HOME}/conf/idp.properties" ]; then
  log "installing conf templates from /opt/carsi/conf"
  cp -rn /opt/carsi/conf/. "${IDP_HOME}/conf/" 2>/dev/null || true
fi
render "${IDP_HOME}/conf/idp.properties" "${IDP_HOME}/conf/idp.properties"

# DB 口令写入 secrets.properties（不落镜像层，只在运行时渲染）
if [ ! -f "${IDP_HOME}/credentials/secrets.properties" ] || \
   ! grep -q '^idp.persistentId.salt' "${IDP_HOME}/credentials/secrets.properties" 2>/dev/null; then
  log "seeding credentials/secrets.properties"
  umask 077
  cat > "${IDP_HOME}/credentials/secrets.properties" <<EOF
idp.persistentId.salt = $(openssl rand -base64 32 | tr -d '\n')
idp.persistentId.sourceAttribute = employeeNumber
idp.persistentId.useUnfilteredAttributes = true
EOF
fi

# ── 3. 首次初始化凭据 ──────────────────────────────────────────────
if [ -f "${IDP_HOME}/credentials/idp-signing.crt" ] && \
   [ -f "${IDP_HOME}/credentials/idp-encryption.crt" ] && \
   [ -f "${IDP_HOME}/metadata/idp-metadata.xml" ]; then
  log "credentials + metadata already present — skipping installer (idempotent)"
else
  log "first boot: running IdP installer (generates signing/encryption/sealer creds)"
  [ -d "${IDP_DIST}/bin" ] || die "IdP distribution not found at ${IDP_DIST}"

  # 官方 installer 需要一个可写目录；凭据直接落到挂载卷
  cd "${IDP_DIST}"
  # OWNER/SEALER 口令通过环境变量传入，避免交互
  sed -i "s|^idp\.sealer\.password=.*|idp.sealer.password=${SEALER_PASSWORD}|" \
      "${IDP_HOME}/conf/idp.properties" 2>/dev/null || true

  IDP_HOME="${IDP_HOME}" \
  JAVA_HOME="${JAVA_HOME}" \
  "${IDP_DIST}/bin/install.sh" \
      -Didp.home="${IDP_HOME}" \
      -Dtarget.dir="${IDP_HOME}" \
      -Didp.entityID="${ENTITY_ID}" \
      -Didp.hostname="${IDP_HOST}" \
      -Didp.scope="${IDP_SCOPE}" \
      -Dsealer.password="${SEALER_PASSWORD}" \
      -Dkeystore.password="${SEALER_PASSWORD}" \
      -DnoPrompt=true \
    || die "IdP installer failed — see output above"

  log "installer finished; credentials:"
  ls -l "${IDP_HOME}/credentials" || true
fi

# 凭据权限收紧
chmod 600 "${IDP_HOME}/credentials"/*.key "${IDP_HOME}/credentials/secrets.properties" 2>/dev/null || true
chown -R "${RUN_USER}:${RUN_USER}" "${IDP_HOME}/credentials" "${IDP_HOME}/metadata" \
        "${IDP_HOME}/logs" "${IDP_HOME}/conf" "${IDP_HOME}/war" 2>/dev/null || true

# ── 4. 部署 war 到 Jetty ───────────────────────────────────────────
if [ ! -f "${JETTY_BASE}/webapps/idp.war" ]; then
  if [ -d "${IDP_HOME}/dist" ] && ls "${IDP_HOME}/dist"/*.war >/dev/null 2>&1; then
    log "linking existing war from ${IDP_HOME}/dist"
    ln -sf "$(ls "${IDP_HOME}/dist"/*.war | head -1)" "${JETTY_BASE}/webapps/idp.war"
  elif [ -d "${IDP_HOME}/edit-webapp" ] && [ -n "$(ls -A "${IDP_HOME}/edit-webapp" 2>/dev/null)" ]; then
    log "build /opt/shibboleth-idp/dist/idp.war from edit-webapp"
    ( cd "${IDP_HOME}" && \
      "${IDP_DIST}/bin/build.sh" -Didp.home="${IDP_HOME}" -DnoPrompt=true ) || \
      log "WARN: bin/build.sh failed — Jetty will attempt to deploy the exploded webapp"
  fi
fi

# ── 5. 启动 Jetty ─────────────────────────────────────────────────
log "starting Jetty 12 (base=${JETTY_BASE})"
cd "${JETTY_BASE}"

exec gosu "${RUN_USER}" java \
  ${JAVA_OPTS:--Xms512m -Xmx1024m -XX:MaxMetaspaceSize=256m -XX:+UseG1GC} \
  -Didp.home="${IDP_HOME}" \
  -Djetty.base="${JETTY_BASE}" \
  -Djetty.home="${JETTY_HOME}" \
  -jar "${JETTY_HOME}/start.jar"
