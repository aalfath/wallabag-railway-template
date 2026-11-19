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

# 4. Install on the first start, run new migrations on later starts.
#    A redeploy can start the new container while the old one still runs, so
#    this step holds a Postgres advisory lock (in a background psql session,
#    released when it ends or the container dies). wallabag's installer must
#    see an empty database, so the lock adds no tables.
q() { psql -qAt -v ON_ERROR_STOP=1 -c "$1"; }
LOCK=27140001
LOCKDIR=$(mktemp -d)
# A random session name: $$ is 1 in every container.
LOCKNAME="wallabag-install-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
mkfifo "$LOCKDIR/in"
PGAPPNAME="$LOCKNAME" psql -qAt -v ON_ERROR_STOP=1 < "$LOCKDIR/in" > /dev/null 2>&1 &
LOCKPID=$!
exec 3> "$LOCKDIR/in"
echo "SELECT pg_advisory_lock($LOCK);" >&3
i=0
until [ "$(q "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a USING (pid) WHERE l.locktype = 'advisory' AND l.objid = $LOCK AND l.granted AND a.application_name = '$LOCKNAME'")" = 1 ]; do
  kill -0 "$LOCKPID" 2>/dev/null || { echo "Could not take the install lock" >&2; exit 1; }
  i=$((i + 1))
  [ $((i % 15)) = 1 ] && echo "Waiting for another container to finish its install or migrations ..."
  sleep 1
done

tables=$(q "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")
settings=0
if [ "$(q "SELECT to_regclass('${P}internal_setting') IS NOT NULL")" = t ]; then
  settings=$(q "SELECT count(*) FROM ${P}internal_setting")
fi
case "$tables:$settings" in
  *[!0-9:]*|:*|*:) echo "Could not read the database state" >&2; exit 1 ;;
esac
if [ "$settings" -gt 0 ]; then
  console doctrine:migrations:migrate --allow-no-migration
else
  if [ "$tables" -gt 0 ]; then
    # Tables but no settings: an earlier install stopped half way. Start over,
    # unless the database holds saved articles.
    if [ "$(q "SELECT to_regclass('${P}entry') IS NOT NULL")" = t ] && [ "$(q "SELECT count(*) FROM ${P}entry")" != 0 ]; then
      echo "The database has articles but no wallabag settings; not touching it" >&2; exit 1
    fi
    echo "An earlier install did not finish: clearing the database and installing again"
    psql -q -v ON_ERROR_STOP=1 -c 'DROP SCHEMA public CASCADE' -c 'CREATE SCHEMA public' >/dev/null
  fi
  echo "Installing wallabag ..."
  console wallabag:install
fi

# 5. The installer always creates wallabag/wallabag. Turn it into our admin
#    (password first, so a failed run is redone on the next start) and send
#    imports through Redis.
if [ "$(psql -qAtc "SELECT count(*) FROM ${P}user WHERE username_canonical = 'wallabag' AND email_canonical = 'wallabag@wallabag.io'")" = 1 ]; then
  if [ -z "${ADMIN_PASSWORD:-}" ]; then echo "ADMIN_PASSWORD is empty" >&2; exit 1; fi
  console fos:user:change-password wallabag "$ADMIN_PASSWORD" || exit 1
  psql -q -v ON_ERROR_STOP=1 -v u="$ADMIN_USERNAME" -v e="$ADMIN_EMAIL" <<SQL
UPDATE ${P}user SET username = :'u', username_canonical = lower(:'u'), email = :'e', email_canonical = lower(:'e')
 WHERE username_canonical = 'wallabag' AND email_canonical = 'wallabag@wallabag.io'
   AND NOT EXISTS (SELECT 1 FROM ${P}user WHERE username_canonical = lower(:'u') OR email_canonical = lower(:'e'));
-- If the admin already exists, lock the leftover default account instead.
UPDATE ${P}user SET enabled = false, username = 'wallabag-disabled-' || id, username_canonical = 'wallabag-disabled-' || id,
       email = 'disabled-' || id || '@invalid', email_canonical = 'disabled-' || id || '@invalid'
 WHERE username_canonical = 'wallabag' AND email_canonical = 'wallabag@wallabag.io';
UPDATE ${P}internal_setting SET value = '1' WHERE name = 'import_with_redis';
SQL
  echo "Admin account ready: $ADMIN_USERNAME"
fi
exec 3>&-
wait "$LOCKPID" || true
rm -r "$LOCKDIR"

# 6. Warm the cache, then run nginx, PHP-FPM and the import worker.
console cache:warmup >/dev/null
echo "wallabag is ready on port $PORT"
exec s6-svscan /etc/s6
