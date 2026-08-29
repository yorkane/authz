# Dockerfile - openresty-base (alpine)
# Custom OpenResty build with extra modules:
#   - lua-nginx-module        (latest master, replaces bundled version)
#   - stream-lua-nginx-module (latest master, replaces bundled version)
#   - lua-resty-core          (latest master, replaces bundled version
#                              so resty.core ABI matches the master C modules)
#   - nginx-dav-ext-module    (WebDAV PROPFIND/OPTIONS/LOCK/UNLOCK)
#   - ngx-fancyindex          (fancy directory listing)
#   - ngx_brotli               (Brotli dynamic and pre-compressed static responses)
#
# Reference: https://github.com/openresty/docker-openresty/blob/master/alpine/Dockerfile
#            https://github.com/openresty/docker-openresty/blob/master/alpine/Dockerfile.fat

# --------------------------------------------------------------------------
# Build-time arguments (overridden by GitHub Actions workflow)
# --------------------------------------------------------------------------
ARG RESTY_IMAGE_BASE="alpine"
ARG RESTY_IMAGE_TAG="3.23.5"
ARG LUA_RESTY_HTTP_VERSION="0.18.0"

FROM ${RESTY_IMAGE_BASE}:${RESTY_IMAGE_TAG} AS lua-resty-http-source
ARG LUA_RESTY_HTTP_VERSION
RUN unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy \
    && apk add --no-cache curl tar \
    && mkdir -p /out \
    && curl -fSL "https://github.com/ledgetech/lua-resty-http/archive/refs/tags/v${LUA_RESTY_HTTP_VERSION}.tar.gz" \
        | tar -xz --strip-components=3 -C /out \
            "lua-resty-http-${LUA_RESTY_HTTP_VERSION}/lib/resty/http.lua" \
            "lua-resty-http-${LUA_RESTY_HTTP_VERSION}/lib/resty/http_connect.lua" \
            "lua-resty-http-${LUA_RESTY_HTTP_VERSION}/lib/resty/http_headers.lua"

# Keep the Brotli source and its git submodule in an independent layer. A
# change to OpenResty configure flags can then reuse this download layer.
FROM ${RESTY_IMAGE_BASE}:${RESTY_IMAGE_TAG} AS ngx-brotli-source
ARG NGX_BROTLI_VERSION="master"
RUN unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy \
    && apk add --no-cache git \
    && git clone --depth=1 --recurse-submodules --branch "${NGX_BROTLI_VERSION}" \
        https://github.com/google/ngx_brotli.git /opt/ngx_brotli

FROM ${RESTY_IMAGE_BASE}:${RESTY_IMAGE_TAG} AS openresty-builder

# https://github.com/openresty/openresty-packaging/blob/master/alpine/openresty/APKBUILD
ARG RESTY_VERSION="1.31.1.1"

# https://github.com/openresty/openresty-packaging/blob/master/alpine/openresty-openssl3/APKBUILD
ARG RESTY_OPENSSL_VERSION="3.5.7"
ARG RESTY_OPENSSL_PATCH_VERSION="3.5.5"
ARG RESTY_OPENSSL_URL_BASE="https://github.com/openssl/openssl/releases/download/openssl-${RESTY_OPENSSL_VERSION}"
ARG RESTY_OPENSSL_BUILD_OPTIONS="no-asm enable-camellia enable-seed enable-rfc3779 enable-cms enable-md2 enable-rc5 \
        enable-weak-ssl-ciphers enable-ssl3 enable-ssl3-method enable-md2 enable-ktls enable-fips \
        "

# https://github.com/openresty/openresty-packaging/blob/master/alpine/openresty-pcre2/APKBUILD
ARG RESTY_PCRE_VERSION="10.47"
ARG RESTY_PCRE_SHA256="c08ae2388ef333e8403e670ad70c0a11f1eed021fd88308d7e02f596fcd9dc16"
ARG RESTY_PCRE_BUILD_OPTIONS="--enable-jit --enable-pcre2grep-jit --disable-bsr-anycrlf --disable-coverage --disable-ebcdic --disable-fuzz-support \
    --disable-jit-sealloc --disable-never-backslash-C --enable-newline-is-lf --enable-pcre2-8 --enable-pcre2-16 --enable-pcre2-32 \
    --enable-pcre2grep-callout --enable-pcre2grep-callout-fork --disable-pcre2grep-libbz2 --disable-pcre2grep-libz --disable-pcre2test-libedit \
    --enable-percent-zt --disable-rebuild-chartables --enable-shared --disable-static --disable-silent-rules --enable-unicode --disable-valgrind \
    "

ARG RESTY_LUAROCKS_VERSION="3.13.0"
ARG RESTY_J="8"
ARG NGX_BROTLI_VERSION="master"

# Versions for extra modules (overridden by workflow to pin exact commits/tags)
ARG LUA_NGINX_MODULE_VERSION="master"
ARG LUA_RESTY_CORE_VERSION="master"
ARG NGX_FANCYINDEX_VERSION="master"
ARG NGX_DAV_EXT_VERSION="master"

# lua-resty-jwt implementation compatible with OpenSSL 3.x through
# resty.openssl; no legacy HMAC_CTX_init dependency.
ARG LUA_RESTY_JWT_VERSION="0.2.6"

ARG RESTY_CONFIG_OPTIONS="\
    --with-compat \
    --without-http_rds_json_module \
    --without-http_rds_csv_module \
    --without-lua_rds_parser \
    --without-mail_pop3_module \
    --without-mail_imap_module \
    --without-mail_smtp_module \
    --with-http_addition_module \
    --with-http_auth_request_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_geoip_module=dynamic \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_image_filter_module=dynamic \
    --with-http_mp4_module \
    --with-http_random_index_module \
    --with-http_realip_module \
    --with-http_secure_link_module \
    --with-http_slice_module \
    --with-http_ssl_module \
    --with-http_stub_status_module \
    --with-http_sub_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-http_xslt_module=dynamic \
    --with-ipv6 \
    --with-mail \
    --with-mail_ssl_module \
    --with-md5-asm \
    --with-sha1-asm \
    --with-stream \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --with-threads \
    "

ARG RESTY_CONFIG_OPTIONS_MORE=""
ARG RESTY_LUAJIT_OPTIONS="--with-luajit-xcflags='-DLUAJIT_NUMMODE=2 -DLUAJIT_ENABLE_LUA52COMPAT'"
ARG RESTY_PCRE_OPTIONS="--with-pcre-jit"

ARG RESTY_ADD_PACKAGE_BUILDDEPS=""
# sqlite-libs: resty.authz 本地认证/绑定存储 (SQLite FFI)
ARG RESTY_ADD_PACKAGE_RUNDEPS="sqlite-libs"
ARG RESTY_EVAL_PRE_CONFIGURE=""
ARG RESTY_EVAL_POST_DOWNLOAD_PRE_CONFIGURE=""
ARG RESTY_EVAL_PRE_MAKE=""
ARG RESTY_EVAL_POST_MAKE=""

# Strip debug symbols from binaries to reduce image size (set to "" to disable)
ARG RESTY_STRIP_BINARIES="1"

COPY --from=ngx-brotli-source /opt/ngx_brotli /opt/ngx_brotli

# These are not intended to be user-specified.
# PCRE2 and OpenSSL3 are pre-built into /usr/local/openresty/{pcre2,openssl3}
# and pulled in via --with-cc-opt / --with-ld-opt rpath.
ARG _RESTY_CONFIG_DEPS="--with-pcre \
    --with-cc-opt='-DNGX_LUA_ABORT_AT_PANIC -I/usr/local/openresty/pcre2/include -I/usr/local/openresty/openssl3/include' \
    --with-ld-opt='-L/usr/local/openresty/pcre2/lib -L/usr/local/openresty/openssl3/lib -Wl,-rpath,/usr/local/openresty/pcre2/lib:/usr/local/openresty/openssl3/lib' \
    "

LABEL maintainer="yorkane"
LABEL resty_version="${RESTY_VERSION}"
LABEL resty_openssl_version="${RESTY_OPENSSL_VERSION}"
LABEL resty_openssl_patch_version="${RESTY_OPENSSL_PATCH_VERSION}"
LABEL resty_pcre_version="${RESTY_PCRE_VERSION}"
LABEL lua_nginx_module_version="${LUA_NGINX_MODULE_VERSION}"
LABEL lua_resty_core_version="${LUA_RESTY_CORE_VERSION}"
LABEL lua_resty_jwt_version="${LUA_RESTY_JWT_VERSION}"
LABEL ngx_fancyindex_version="${NGX_FANCYINDEX_VERSION}"
LABEL ngx_dav_ext_module_version="${NGX_DAV_EXT_VERSION}"

# Runtime libraries are installed only in the final stage below. Keeping
# them out of the builder keeps the shipped image independent of the toolchain.
# --------------------------------------------------------------------------
# Single RUN: install build deps → build PCRE2 → build OpenSSL →
#             clone modules → compile OpenResty → install LuaRocks →
#             extract envsubst → strip → cleanup
# --------------------------------------------------------------------------
RUN unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy \
    && apk add --no-cache --virtual .build-deps \
        build-base \
        binutils \
        cmake \
        coreutils \
        curl \
        gd-dev \
        geoip-dev \
        git \
        libxslt-dev \
        linux-headers \
        make \
        perl-dev \
        readline-dev \
        zlib-dev \
        ${RESTY_ADD_PACKAGE_BUILDDEPS}

# ── Build PCRE2 (shared, installed under openresty prefix) ────────────
RUN unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy \
    && cd /tmp \
    && curl -fSL "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${RESTY_PCRE_VERSION}/pcre2-${RESTY_PCRE_VERSION}.tar.gz" \
            -o "pcre2-${RESTY_PCRE_VERSION}.tar.gz" \
    && echo "${RESTY_PCRE_SHA256}  pcre2-${RESTY_PCRE_VERSION}.tar.gz" | sha256sum -c \
    && tar xzf "pcre2-${RESTY_PCRE_VERSION}.tar.gz" \
    && cd "/tmp/pcre2-${RESTY_PCRE_VERSION}" \
    && CFLAGS="-g -O3" ./configure \
        --prefix=/usr/local/openresty/pcre2 \
        --libdir=/usr/local/openresty/pcre2/lib \
        ${RESTY_PCRE_BUILD_OPTIONS} \
    && CFLAGS="-g -O3" make -j${RESTY_J} \
    && CFLAGS="-g -O3" make -j${RESTY_J} install \
    && cd /tmp \
    && rm -rf "pcre2-${RESTY_PCRE_VERSION}" "pcre2-${RESTY_PCRE_VERSION}.tar.gz" \
    \
    # ── Build OpenSSL3 (shared, with OpenResty sess_set_get_cb_yield patch) ─
    && curl -fSL "${RESTY_OPENSSL_URL_BASE}/openssl-${RESTY_OPENSSL_VERSION}.tar.gz" \
            -o "openssl-${RESTY_OPENSSL_VERSION}.tar.gz" \
    && tar xzf "openssl-${RESTY_OPENSSL_VERSION}.tar.gz" \
    && cd "openssl-${RESTY_OPENSSL_VERSION}" \
    && if [ "$(echo ${RESTY_OPENSSL_VERSION} | cut -c 1-2)" = "3." ] ; then \
         echo "==> patching OpenSSL 3.x for OpenResty" \
         && curl -fsSL "https://raw.githubusercontent.com/openresty/openresty/master/patches/openssl-${RESTY_OPENSSL_PATCH_VERSION}-sess_set_get_cb_yield.patch" | patch -p1 ; \
       fi \
    && ./config \
        shared zlib -g \
        --prefix=/usr/local/openresty/openssl3 \
        --libdir=lib \
        -Wl,-rpath,/usr/local/openresty/openssl3/lib \
        ${RESTY_OPENSSL_BUILD_OPTIONS} \
    # OpenSSL's default target also compiles hundreds of test binaries; the
    # runtime only needs the software libraries and CLI.
    && make -j${RESTY_J} build_libs build_modules apps/openssl \
    && make install_dev install_engines install_modules \
    && mkdir -p /usr/local/openresty/openssl3/bin \
    && cp apps/openssl /usr/local/openresty/openssl3/bin/openssl \
    && cd /tmp \
    && rm -rf "openssl-${RESTY_OPENSSL_VERSION}" "openssl-${RESTY_OPENSSL_VERSION}.tar.gz" \
    \
    # ── Clone extra modules ───────────────────────────────────────────────
    # lua-nginx-module master (will replace the bundled ngx_lua in OpenResty)
    && git clone --depth=1 --branch "${LUA_NGINX_MODULE_VERSION}" \
            https://github.com/openresty/lua-nginx-module.git \
            /tmp/lua-nginx-module \
    # stream-lua-nginx-module master (paired replacement)
    && git clone --depth=1 \
            https://github.com/openresty/stream-lua-nginx-module.git \
            /tmp/stream-lua-nginx-module \
    # lua-resty-core master (must match the master ngx_lua 0.10.32 ABI;
    # bundled lua-resty-core in OpenResty 1.31.1.1 still expects 0.10.31)
    && git clone --depth=1 --branch "${LUA_RESTY_CORE_VERSION}" \
            https://github.com/openresty/lua-resty-core.git \
            /tmp/lua-resty-core \
    # nginx-dav-ext-module (WebDAV PROPFIND/OPTIONS/LOCK/UNLOCK)
    && git clone --depth=1 --branch "${NGX_DAV_EXT_VERSION}" \
            https://github.com/arut/nginx-dav-ext-module.git \
            /tmp/nginx-dav-ext-module \
    # ngx-fancyindex (fancy directory listing)
    && git clone --depth=1 --branch "${NGX_FANCYINDEX_VERSION}" \
            https://github.com/aperezdc/ngx-fancyindex.git \
            /tmp/ngx-fancyindex \
    && cp -a /opt/ngx_brotli /tmp/ngx_brotli \
    \
    # ── Download & build OpenResty ────────────────────────────────────────
    && if [ -n "${RESTY_EVAL_PRE_CONFIGURE}" ]; then eval $(echo ${RESTY_EVAL_PRE_CONFIGURE}); fi \
    && curl -fSL "https://openresty.org/download/openresty-${RESTY_VERSION}.tar.gz" \
            -o "openresty-${RESTY_VERSION}.tar.gz" \
    && tar xzf "openresty-${RESTY_VERSION}.tar.gz" \
    && rm  -f  "openresty-${RESTY_VERSION}.tar.gz" \
    # Replace bundled ngx_lua with the latest master clone
    && BUNDLED_NGX_LUA=$(ls -d /tmp/openresty-${RESTY_VERSION}/bundle/ngx_lua-* 2>/dev/null | head -1) \
    && if [ -n "${BUNDLED_NGX_LUA}" ]; then \
         echo "==> Replacing $(basename ${BUNDLED_NGX_LUA}) with lua-nginx-module:${LUA_NGINX_MODULE_VERSION}"; \
         rm -rf "${BUNDLED_NGX_LUA}"; \
         cp -r  /tmp/lua-nginx-module "${BUNDLED_NGX_LUA}"; \
       fi \
    # Replace bundled ngx_stream_lua with the latest master clone
    && BUNDLED_STREAM_LUA=$(ls -d /tmp/openresty-${RESTY_VERSION}/bundle/ngx_stream_lua-* 2>/dev/null | head -1) \
    && if [ -n "${BUNDLED_STREAM_LUA}" ]; then \
         echo "==> Replacing $(basename ${BUNDLED_STREAM_LUA}) with stream-lua-nginx-module:master"; \
         rm -rf "${BUNDLED_STREAM_LUA}"; \
         cp -r  /tmp/stream-lua-nginx-module "${BUNDLED_STREAM_LUA}"; \
       fi \
    # Replace bundled lua-resty-core with the latest master clone so that
    # resty.core's ABI check (which pins ngx_lua 10032 / ngx_stream_lua 20)
    # matches our master-cloned C modules.
    && BUNDLED_LUA_RESTY_CORE=$(ls -d /tmp/openresty-${RESTY_VERSION}/bundle/lua-resty-core-* 2>/dev/null | head -1) \
    && if [ -n "${BUNDLED_LUA_RESTY_CORE}" ]; then \
         echo "==> Replacing $(basename ${BUNDLED_LUA_RESTY_CORE}) with lua-resty-core:${LUA_RESTY_CORE_VERSION}"; \
         rm -rf "${BUNDLED_LUA_RESTY_CORE}"; \
         cp -r  /tmp/lua-resty-core "${BUNDLED_LUA_RESTY_CORE}"; \
       fi \
    # Build the Brotli encoder library consumed by ngx_brotli's filter module.
    && cd /tmp/ngx_brotli/deps/brotli \
    && cmake -S . -B out \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_C_FLAGS="-O3" \
        -DCMAKE_CXX_FLAGS="-O3" \
    && cmake --build out --config Release --target brotlienc -j${RESTY_J} \
    && cd "/tmp/openresty-${RESTY_VERSION}" \
    && if [ -n "${RESTY_EVAL_POST_DOWNLOAD_PRE_CONFIGURE}" ]; then eval $(echo ${RESTY_EVAL_POST_DOWNLOAD_PRE_CONFIGURE}); fi \
    && eval ./configure -j${RESTY_J} \
        ${_RESTY_CONFIG_DEPS} \
        ${RESTY_CONFIG_OPTIONS} \
        ${RESTY_CONFIG_OPTIONS_MORE} \
        ${RESTY_LUAJIT_OPTIONS} \
        ${RESTY_PCRE_OPTIONS} \
        --add-module=/tmp/nginx-dav-ext-module \
        --add-module=/tmp/ngx-fancyindex \
        --add-module=/tmp/ngx_brotli \
    && if [ -n "${RESTY_EVAL_PRE_MAKE}" ]; then eval $(echo ${RESTY_EVAL_PRE_MAKE}); fi \
    && make -j${RESTY_J} \
    && make install \
    \
    # ── Fetch lua-resty-jwt ──────────────────────────────────────────
    # NOTE: must run AFTER `make install` because /usr/local/openresty/lualib
    # does not exist before OpenResty is installed.
    && curl -fSL "https://codeload.github.com/api7/lua-resty-jwt/tar.gz/refs/tags/v${LUA_RESTY_JWT_VERSION}" \
            -o "lua-resty-jwt.tar.gz" \
    && tar xzf "lua-resty-jwt.tar.gz" \
    && cp "lua-resty-jwt-${LUA_RESTY_JWT_VERSION}/lib/resty/jwt.lua" \
          /usr/local/openresty/lualib/resty/jwt.lua \
    && cp "lua-resty-jwt-${LUA_RESTY_JWT_VERSION}/lib/resty/jwt-validators.lua" \
          /usr/local/openresty/lualib/resty/jwt-validators.lua \
    && cp "lua-resty-jwt-${LUA_RESTY_JWT_VERSION}/lib/resty/evp.lua" \
          /usr/local/openresty/lualib/resty/evp.lua \
    && rm -rf "lua-resty-jwt-${LUA_RESTY_JWT_VERSION}" "lua-resty-jwt.tar.gz" \
    \
    # ── Install LuaRocks ──────────────────────────────────────────────────
    && cd /tmp \
    && curl -fSL "https://luarocks.github.io/luarocks/releases/luarocks-${RESTY_LUAROCKS_VERSION}.tar.gz" \
            -o "luarocks-${RESTY_LUAROCKS_VERSION}.tar.gz" \
    && tar xzf "luarocks-${RESTY_LUAROCKS_VERSION}.tar.gz" \
    && cd "luarocks-${RESTY_LUAROCKS_VERSION}" \
    && ./configure \
        --prefix=/usr/local/openresty/luajit \
        --with-lua=/usr/local/openresty/luajit \
        --with-lua-include=/usr/local/openresty/luajit/include/luajit-2.1 \
    && make build \
    && make install \
    && cd /tmp \
    && rm -rf "luarocks-${RESTY_LUAROCKS_VERSION}" "luarocks-${RESTY_LUAROCKS_VERSION}.tar.gz" \
    \
    # ── Extract envsubst binary before removing gettext ───────────────────
    && apk add --no-cache --virtual .gettext gettext \
    && mv /usr/bin/envsubst /tmp/envsubst \
    \
    # ── Strip debug symbols + drop static libs / man / dev headers ────────
    && if [ -n "${RESTY_STRIP_BINARIES}" ]; then \
         echo "==> Stripping binaries ..."; \
         rm -Rf /usr/local/openresty/openssl3/bin/c_rehash \
                /usr/local/openresty/openssl3/lib/*.a \
                /usr/local/openresty/openssl3/include ; \
         find /usr/local/openresty/openssl3 -type f -perm -u+x -exec strip --strip-unneeded {} + ; \
         rm -Rf /usr/local/openresty/pcre2/bin /usr/local/openresty/pcre2/share ; \
         find /usr/local/openresty/pcre2 -type f -perm -u+x -exec strip --strip-unneeded {} + ; \
         rm -Rf /usr/local/openresty/luajit/lib/*.a /usr/local/openresty/luajit/share/man ; \
         # NOTE: keep luajit/include so downstream images can compile luarocks C extensions (e.g. lua-vips) \
         rm -rf /usr/local/openresty/luajit/lib/libluajit-5.1.a \
                /usr/local/openresty/luajit/lib/libluajit-5.1.la ; \
         find /usr/local/openresty/luajit -type f -perm -u+x -exec strip --strip-unneeded {} + ; \
         find /usr/local/openresty/nginx -type f -perm -u+x -exec strip --strip-unneeded {} + ; \
         rm -rf /usr/local/openresty/pod /usr/local/openresty/resty.index ; \
       fi \
    \
    # ── Cleanup build artifacts ──────────────────────────────────────────
    && if [ -n "${RESTY_EVAL_POST_MAKE}" ]; then eval $(echo ${RESTY_EVAL_POST_MAKE}); fi \
    && cd /tmp \
    && rm -rf \
        "openresty-${RESTY_VERSION}" \
        /tmp/lua-nginx-module \
        /tmp/stream-lua-nginx-module \
        /tmp/lua-resty-core \
        /tmp/nginx-dav-ext-module \
        /tmp/ngx-fancyindex \
        /tmp/ngx_brotli \
        /opt/ngx_brotli \
    \
    # ── Remove build toolchain ────────────────────────────────────────────
    && apk del .build-deps .gettext \
    \
    # ── Restore envsubst and setup log symlinks ───────────────────────────
    && mv /tmp/envsubst /usr/local/bin/envsubst \
    && mkdir -p /var/run/openresty \
    && ln -sf /dev/stdout /usr/local/openresty/nginx/logs/access.log \
    && ln -sf /dev/stderr /usr/local/openresty/nginx/logs/error.log

# --------------------------------------------------------------------------
# Runtime stage: keep only OpenResty, runtime libraries and application files.
# --------------------------------------------------------------------------
ARG RESTY_IMAGE_BASE="alpine"
ARG RESTY_IMAGE_TAG="3.23.5"
FROM ${RESTY_IMAGE_BASE}:${RESTY_IMAGE_TAG}
ARG RESTY_ADD_PACKAGE_RUNDEPS="sqlite-libs"

COPY --from=openresty-builder /usr/local/openresty /usr/local/openresty
COPY --from=openresty-builder /usr/local/bin/envsubst /usr/local/bin/envsubst

RUN unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy \
    && apk add --no-cache \
        ca-certificates \
        gd \
        geoip \
        libgcc \
        libintl \
        libxslt \
        libxml2 \
        tzdata \
        zlib \
        ${RESTY_ADD_PACKAGE_RUNDEPS} \
    && mkdir -p /var/run/openresty

# --------------------------------------------------------------------------
# Runtime environment
# --------------------------------------------------------------------------
ENV PATH="/usr/local/openresty/luajit/bin:/usr/local/openresty/nginx/sbin:/usr/local/openresty/bin:${PATH}"

ENV LUA_PATH="/usr/local/openresty/site/lualib/?.ljbc;/usr/local/openresty/site/lualib/?/init.ljbc;/usr/local/openresty/lualib/?.ljbc;/usr/local/openresty/lualib/?/init.ljbc;/usr/local/openresty/site/lualib/?.lua;/usr/local/openresty/site/lualib/?/init.lua;/usr/local/openresty/lualib/?.lua;/usr/local/openresty/lualib/?/init.lua;./?.lua;/usr/local/openresty/luajit/share/luajit-2.1/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/local/openresty/luajit/share/lua/5.1/?.lua;/usr/local/openresty/luajit/share/lua/5.1/?/init.lua"

ENV LUA_CPATH="/usr/local/openresty/site/lualib/?.so;/usr/local/openresty/lualib/?.so;./?.so;/usr/local/lib/lua/5.1/?.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so;/usr/local/openresty/luajit/lib/lua/5.1/?.so"

COPY --from=lua-resty-http-source /out/ /usr/local/openresty/lualib/resty/

# ── 项目 Lua 库 ─────────────────────────────────────────────────────
# 整体复制到 site/lualib，和开发时只读挂载目录保持完全一致；同时不遮蔽
# OpenResty 自带的 /usr/local/openresty/lualib 模块。
COPY lualib/ /usr/local/openresty/site/lualib/
# Container maintenance command for recovering the built-in admin account.
COPY scripts/admin_password_reset.lua /usr/local/openresty/admin_password_reset.lua
COPY scripts/admin_password_reset /usr/local/bin/admin_password_reset
RUN chmod +x /usr/local/bin/admin_password_reset
# 静态 SSI 管理界面
COPY admin/ /usr/local/openresty/nginx/html/admin/

# Generate Brotli sidecars at image build time. Because this step follows
# COPY admin, changing a frontend asset invalidates only this small layer.
# index.html contains the SSI menu include and must be processed by the SSI
# filter instead of being served directly from a Brotli sidecar.
RUN apk add --no-cache --virtual .brotli-tools brotli \
    && find /usr/local/openresty/nginx/html/admin -type f ! -name '*.br' ! -name 'index.html' \
        -exec sh -c 'brotli -f -q 11 "$1" -o "$1.br"' _ {} \; \
    && apk del .brotli-tools
# 网关 nginx 主模板与 HTTP/HTTPS 共用 server 配置
COPY conf/nginx.conf.template /usr/local/openresty/nginx/conf/nginx.conf.template
COPY conf/server.conf.template /usr/local/openresty/nginx/conf/server.conf.template
COPY conf/openssl.cnf /usr/local/openresty/nginx/conf/openssl.cnf
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 80 443 6080 6443

STOPSIGNAL SIGQUIT

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
