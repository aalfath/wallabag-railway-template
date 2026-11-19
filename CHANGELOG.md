# Changelog

## 2.6.18 (2026-11-19)

First version of the template.

- wallabag 2.6.18 (security release). The official `wallabag/wallabag:2.6.18` image wasn't on Docker Hub yet, so the Dockerfile starts from `wallabag/wallabag:2.6.17@sha256:9055d92d…` and installs the official 2.6.18 release tarball (sha256-checked) with upstream's own steps.
- Services: wallabag (this repo), Railway Postgres, Railway Redis (import queue).
- Admin account from `ADMIN_USERNAME` / generated `ADMIN_PASSWORD`; the default `wallabag` / `wallabag` login is never left active.
- Imports run in the background through Redis, served by one worker inside the wallabag service.
- Article images and sessions on the `/data` volume.
