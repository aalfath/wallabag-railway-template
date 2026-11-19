# wallabag for Railway: the official image, pinned by version and digest,
# plus a small start script and a Redis import worker.
FROM wallabag/wallabag:2.6.17@sha256:9055d92d6e7973abea2d902ecb5459f6063fce05595eaef37f6750e49ff8cdee

# wallabag 2.6.18 (security release, 2026-11-19) is not on Docker Hub yet, so the
# official release tarball replaces the app inside the 2.6.17 image, checked by
# its sha256 and installed with the same steps as upstream's Dockerfile.
# Drop this block once the image tag for this version exists.
ARG WALLABAG_VERSION=2.6.18
ARG WALLABAG_SHA256=c62813acd0466e94e6b0c91bb7753c16ce381f8eabdf551db36bf311ff8f47ea
RUN set -ex \
 && curl -fsSL -o /tmp/wallabag.tar.gz "https://github.com/wallabag/wallabag/releases/download/${WALLABAG_VERSION}/wallabag-${WALLABAG_VERSION}.tar.gz" \
 && echo "${WALLABAG_SHA256}  /tmp/wallabag.tar.gz" | sha256sum -c - \
 && rm -r /var/www/wallabag \
 && mkdir /var/www/wallabag \
 && tar xzf /tmp/wallabag.tar.gz -C /var/www/wallabag --strip-components=1 \
 && rm /tmp/wallabag.tar.gz \
 && cd /var/www/wallabag \
 && mkdir -p data/assets \
 && envsubst < /etc/wallabag/parameters.template.yml > app/config/parameters.yml \
 && SYMFONY_ENV=prod composer install --no-dev -o --prefer-dist --no-progress \
 && rm -rf /root/.composer/* var/cache/* var/logs/* var/sessions/* \
 && chown -R nobody:nobody /var/www/wallabag

# Fixed settings for this template (override any of them as a service variable).
ENV SYMFONY__ENV__DATABASE_DRIVER=pdo_pgsql \
    SYMFONY__ENV__DATABASE_CHARSET=utf8 \
    SYMFONY__ENV__FOSUSER_REGISTRATION=false \
    SYMFONY__ENV__MAILER_DSN=null://null \
    SYMFONY__ENV__SERVER_NAME=wallabag \
    PORT=80 \
    DATA_DIR=/data

COPY rootfs/ /
RUN chmod 755 /railway-start.sh /etc/s6/import-worker/run /etc/s6/import-worker/finish

WORKDIR /var/www/wallabag
EXPOSE 80
ENTRYPOINT ["/railway-start.sh"]
