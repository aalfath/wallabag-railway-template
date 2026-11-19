[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/wallabag-2?utm_medium=integration&utm_source=button&utm_campaign=wallabag)

# wallabag on Railway

A one-click [Railway](https://railway.com) template for [wallabag](https://wallabag.org), the open-source read-it-later app (MIT licence).

It deploys **wallabag 2.6.18** with three services:

| Service | What it runs | Storage |
|---|---|---|
| `wallabag` | Built from this repo: the official `wallabag/wallabag` image (nginx + PHP-FPM) plus a start script and a Redis import worker | Volume at `/data` (downloaded article images, login sessions) |
| `Postgres` | Railway's PostgreSQL | Its own volume |
| `Redis` | Railway's Redis: the import queue | Its own volume |

## What happens on deploy

1. The start script writes wallabag's config from the service variables and waits for Postgres.
2. First start: it runs `wallabag:install`, then turns the installer's default `wallabag` / `wallabag` account into your admin (`ADMIN_USERNAME`, generated `ADMIN_PASSWORD`). The default login never works. Later starts run the database migrations. A Postgres advisory lock makes sure only one container installs or migrates at a time, even when a redeploy overlaps.
3. It switches imports to Redis, so large Pocket, Instapaper, Omnivore, browser or wallabag imports run in the background. One worker process inside the `wallabag` service serves every import queue.
4. nginx, PHP-FPM and the import worker start under s6. Railway checks `GET /api/info`.

## Variables (`wallabag` service)

| Variable | Default | Notes |
|---|---|---|
| `ADMIN_USERNAME` | `admin` | Admin login, used on the first deploy only |
| `ADMIN_PASSWORD` | generated, 24 characters | Read it in the service's **Variables** tab. Change it later in wallabag (**Config → Password**) |
| `SYMFONY__ENV__SECRET` | generated | Symfony secret |
| `SYMFONY__ENV__DOMAIN_NAME` | `https://${{RAILWAY_PUBLIC_DOMAIN}}` | Set it to `https://YOUR-DOMAIN` if you add a custom domain |
| `SYMFONY__ENV__DATABASE_*` | references to `Postgres` | Don't change |
| `SYMFONY__ENV__REDIS_*` | references to `Redis` | Don't change |
| `PORT` | `80` | Port nginx listens on |

Optional, add them yourself when you need them:

- `SYMFONY__ENV__MAILER_DSN`: email, for example `smtp://USER:PASSWORD@smtp.example.com:587` (default `null://null`, no email). Also set `SYMFONY__ENV__FROM_EMAIL`.
- `SYMFONY__ENV__FOSUSER_REGISTRATION=true`: public sign-up (needs email, off by default).
- `ADMIN_EMAIL`: the admin's email on the first deploy (default `admin@example.com`; change it later in **Config → User information**).
- `PHP_MEMORY_LIMIT`: default `256M`.

## Updates

This template builds from this repository. When we bump wallabag here, Railway shows an "update available" notice on your project, and you choose when to apply it. Read [CHANGELOG.md](CHANGELOG.md) first. Migrations run by themselves on the next start. Back up Postgres before a major version.

## Local test

`docker compose up --build`, then open http://localhost:8080 and log in as `admin` / `local-test-only`. The compose file is for testing only.

## Licence

wallabag is MIT-licensed. The files in this repository are MIT too.
