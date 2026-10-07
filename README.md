# carolina-codes-perl

Read-only v1 polyglot API for Carolina Code Conference. Queries `v1_*` SQL views over `HTTP::Daemon` and `DBI`/`DBD::Pg`.

Production language is the `perl:5.40-slim` image. The process reports that interpreter as `$^V` (`LANGUAGE_VERSION` in `app.pl`). A newer `perl` on a developer machine is not the project version.

Framework is `HTTP::Daemon` 6.17.

Runtime packages pinned in `cpanfile`: `HTTP::Message` 7.04, `HTTP::Tiny` 0.096, `DBI` 1.652, `DBD::Pg` 3.21.2, `JSON` 4.11, and `URI` 5.36. The test phase requires `Test::More` with no version pin. Develop-only pins, installed by `make deps` and left out of the production image: `Perl::Critic` 1.156, `Perl::Tidy` 20260826, and `CPAN::Audit` 20260622.001.

Working notes for agents live in `AGENTS.md`, `MEMORY.md`, and `DECISIONS.md`.

```
cpanm --local-lib=local --installdeps .
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/carolina_dev \
CAROLINA_URL=http://127.0.0.1:4000 \
POLYGLOT_REGISTER_TOKEN=dev \
PUBLIC_BASE_URL=http://127.0.0.1:4006 \
PORT=4006 \
perl app.pl
```

`GET /health` returns `{"ok":true}` without touching Postgres. The listener binds IPv6 dual-stack (`::`). Registration runs beside that listener, so a slow CMS does not delay the first request. `fly.toml` keeps one machine running in `iad` (`min_machines_running = 1`).

```bash
make test         # prove TAP suite (loads shipped app.pl)
make sast         # Perl::Critic SAST (injection/command-exec) on app.pl
make audit        # cpan-audit of declared CPAN deps
make lint         # perltidy --assert-tidy (check-only)
make secrets      # gitleaks detect --source .
make check        # all of the above
make hooks        # install local pre-commit hooks
make deps         # cpanm local-lib runtime + test + develop tools
```

Develop tools (`Perl::Critic`, `Perl::Tidy`, `CPAN::Audit`) are not in the production image. Install them with `make deps` (needs `cpanm` on PATH).

Pre-commit runs the same five checks (`local tests`, `static security scanner`, `3rd-party dependency scanner`, `gitleaks`, `perltidy`). Install once with `make hooks` (needs `pre-commit` on PATH). Emergency skip: `SKIP=local-tests,sast,audit,gitleaks,lint git commit`.
