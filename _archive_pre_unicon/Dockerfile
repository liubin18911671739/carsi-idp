# syntax=docker/dockerfile:1

# ─────────────────────────────────────────────────────────────────
# CARSI / Shibboleth IdP 5.2.2  —  Multi-stage image
#
#   构建源（与 CARSI 官方安装包同源，全部来自 ds.carsi.edu.cn）:
#     • shibboleth-identity-provider-5.2.2.tar.gz   (43.5 MB, 官方分发)
#     • jetty-home-12.1.9.tar.gz                    (Jetty 12.1.9 官方分发)
#     • java-idp-jetty-base (branch 12)             (Shibboleth 官方 jetty-base 模板)
#
#   运行时: Ubuntu 22.04 + OpenJDK 17 (Jakarta Servlet 6.1 / EE10)
#
#   ⚠ IdP 5.1+ 基于 Jakarta Servlet 6.1 → Jetty 12 必须使用 EE10 模块集，
#     用 EE8/EE9 模块会在部署 war 时抛 ClassNotFoundException(jakarta.*)。
# ─────────────────────────────────────────────────────────────────

# ───────────────────────── Stage 1: fetch ─────────────────────────
FROM ubuntu:22.04 AS fetch

ARG CARSI_DIST=https://ds.carsi.edu.cn/5.0inst/v1
ARG JETTY_VER=12.1.9
ARG IDP_VER=5.2.2

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl tar gzip git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /stage

# 1) 官方 IdP 分发包（含 bin/install.sh + webapp/ + bin/lib/idp-installer）
RUN curl -fsSL -m 300 -o idp.tar.gz \
      "${CARSI_DIST}/shibboleth-identity-provider-${IDP_VER}.tar.gz" \
 && mkdir -p idp && tar -xzf idp.tar.gz -C idp --strip-components=1 \
 && test -x idp/bin/install.sh \
 && ls -l idp/ | head

# 2) Jetty 12.1.9 官方分发
RUN curl -fsSL -m 300 -o jetty.tar.gz \
      "${CARSI_DIST}/jetty-home-${JETTY_VER}.tar.gz" \
 && mkdir -p jetty-home && tar -xzf jetty.tar.gz -C jetty-home --strip-components=1 \
 && java -jar jetty-home/start.jar --version 2>/dev/null || true

# 3) Shibboleth 官方 jetty-base 模板（含 idp.ini / idp.xml / keystore 布局）
RUN git clone --depth 1 -b 12 https://git.shibboleth.net/git/java-idp-jetty-base.git jetty-base \
 && ls -R jetty-base/src/main/resources/jetty-base | head -40

# ──────────────────────── Stage 2: runtime ────────────────────────
FROM ubuntu:22.04 AS runtime

LABEL org.opencontainers.image.title="carsi-shibboleth-idp" \
      org.opencontainers.image.description="CARSI Shibboleth IdP 5.2.2 — Jetty 12.1.9 + OpenJDK 17 (Jakarta Servlet 6.1/EE10)" \
      org.opencontainers.image.vendor="CARSI / Shibboleth" \
      org.opencontainers.image.licenses="Apache-2.0"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    JETTY_HOME=/opt/jetty \
    JETTY_BASE=/opt/jetty-base \
    IDP_HOME=/opt/shibboleth-idp \
    LANG=zh_CN.UTF-8 \
    LC_ALL=zh_CN.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openjdk-17-jre-headless \
      ca-certificates tzdata curl tini gosu openssl locales \
 && sed -i 's/^# *\(zh_CN.UTF-8\)/\1/' /etc/locale.gen \
 && locale-gen zh_CN.UTF-8 \
 && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone \
 && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /stage/jetty-home/  ${JETTY_HOME}/
COPY --from=fetch /stage/idp/         /opt/idp-dist/
COPY --from=fetch /stage/jetty-base/src/main/resources/jetty-base/ ${JETTY_BASE}/

# Jetty modules: EE10 (Jakarta Servlet 6.1) + ssl + forwarded + deploy
RUN cd ${JETTY_BASE} \
 && java -jar ${JETTY_HOME}/start.jar --add-modules=server,http,https,ssl,ee10-deploy,ee10-webapp,ee10-servlet,ext,resources,client,forwarded,logging-jetty \
 && mkdir -p ${JETTY_BASE}/webapps ${JETTY_BASE}/lib/ext \
 && rm -rf ${JETTY_BASE}/webapps/*

RUN mkdir -p ${IDP_HOME}/{conf,credentials,metadata,logs,war,flows,views,edit-webapp,dist} \
 && cp -r /opt/idp-dist/webapp/* ${IDP_HOME}/edit-webapp/ 2>/dev/null || true \
 && cp /opt/idp-dist/LICENSE.txt ${IDP_HOME}/ 2>/dev/null || true

COPY conf/ /opt/carsi/conf/
COPY scripts/ /opt/carsi/scripts/

RUN chmod +x /opt/carsi/scripts/*.sh \
 && addgroup --system jetty \
 && adduser --system --ingroup jetty --home ${JETTY_BASE} jetty \
 && chown -R jetty:jetty ${JETTY_HOME} ${JETTY_BASE} ${IDP_HOME} /opt/carsi /opt/idp-dist

COPY conf/jetty/idp.ini      ${JETTY_BASE}/start.d/idp.ini
COPY conf/jetty/jetty-http.xml   ${JETTY_BASE}/etc/jetty-http.xml
COPY conf/jetty/jetty-deploy.xml ${JETTY_BASE}/etc/jetty-deploy.xml

# 只暴露内网端口；TLS 由 nginx 服务终止
EXPOSE 8080

VOLUME ["/opt/shibboleth-idp/credentials", \
        "/opt/shibboleth-idp/metadata", \
        "/opt/shibboleth-idp/conf", \
        "/opt/shibboleth-idp/logs"]

HEALTHCHECK --interval=30s --timeout=6s --start-period=120s --retries=6 \
  CMD curl -fsS http://127.0.0.1:8080/idp/shibboleth -o /dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/carsi/scripts/entrypoint.sh"]
CMD ["run"]
