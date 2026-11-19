#!/bin/sh
# Start wallabag on Railway: write the config from the service variables, put
# images and sessions on the volume, install or migrate the database, replace
# the installer's default wallabag/wallabag account with the admin from
# ADMIN_USERNAME and ADMIN_PASSWORD, then run nginx, PHP-FPM and the Redis
# import worker under s6.
set -eu
cd /var/www/wallabag

: "${PORT:=80}"
: "${DATA_DIR:=/data}"
: "${ADMIN_USERNAME:=admin}"
: "${ADMIN_EMAIL:=${ADMIN_USERNAME}@example.com}"
P="${SYMFONY__ENV__DATABASE_TABLE_PREFIX:-wallabag_}"

console() { s6-setuidgid nobody php bin/console --env=prod --no-interaction "$@"; }

# 1. Config from the environment (the upstream image's own templates).
envsubst < /etc/wallabag/parameters.template.yml > app/config/parameters.yml
envsubst < /etc/wallabag/php-wallabag.template.ini > /etc/php82/conf.d/50_wallabag.ini
sed -i "s/listen \[::\]:[0-9]* ipv6only=off;/listen [::]:${PORT} ipv6only=off;/" /etc/nginx/nginx.conf

# 2. Downloaded images and login sessions live on the volume.
mkdir -p "$DATA_DIR/images" "$DATA_DIR/sessions"
chown nobody:nobody "$DATA_DIR/images" "$DATA_DIR/sessions"
rm -rf web/assets/images var/sessions var/cache/*
ln -s "$DATA_DIR/images" web/assets/images
ln -s "$DATA_DIR/sessions" var/sessions

# 3. Wait for Postgres.
export PGHOST="$SYMFONY__ENV__DATABASE_HOST" PGPORT="${SYMFONY__ENV__DATABASE_PORT:-5432}" \
       PGUSER="$SYMFONY__ENV__DATABASE_USER" PGPASSWORD="$SYMFONY__ENV__DATABASE_PASSWORD" \
       PGDATABASE="$SYMFONY__ENV__DATABASE_NAME"
i=0
until psql -qAtc 'SELECT 1' >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -ge 90 ]; then echo "Postgres at $PGHOST:$PGPORT is not reachable" >&2; exit 1; fi
  echo "Waiting for Postgres ..."
  sleep 2
done

# 4. First start: install. Later starts: run any new migrations.
if [ "$(psql -qAtc "SELECT to_regclass('${P}user') IS NOT NULL")" = t ]; then
  console doctrine:migrations:migrate --allow-no-migration
else
  echo "Installing wallabag ..."
  console wallabag:install
fi

# 5. The installer always creates wallabag/wallabag. Turn it into our admin
#    (password first, so a failed run is redone on the next start) and send
#    imports through Redis.
if [ "$(psql -qAtc "SELECT count(*) FROM ${P}user WHERE username_canonical = 'wallabag' AND email_canonical = 'wallabag@wallabag.io'")" = 1 ]; then
  if [ -z "${ADMIN_PASSWORD:-}" ]; then echo "ADMIN_PASSWORD is empty" >&2; exit 1; fi
  console fos:user:change-password wallabag "$ADMIN_PASSWORD"
  psql -q -v ON_ERROR_STOP=1 -v u="$ADMIN_USERNAME" -v e="$ADMIN_EMAIL" <<SQL
UPDATE ${P}user SET username = :'u', username_canonical = lower(:'u'), email = :'e', email_canonical = lower(:'e')
 WHERE username_canonical = 'wallabag' AND email_canonical = 'wallabag@wallabag.io';
UPDATE ${P}internal_setting SET value = '1' WHERE name = 'import_with_redis';
SQL
  echo "Admin account ready: $ADMIN_USERNAME"
fi

# 6. Warm the cache, then run nginx, PHP-FPM and the import worker.
console cache:warmup >/dev/null
echo "wallabag is ready on port $PORT"
exec s6-svscan /etc/s6
