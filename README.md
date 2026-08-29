# carolina-codes-perl

Read-only v1 polyglot API for Carolina Code Conference. Queries `v1_*` SQL views over `HTTP::Daemon` and `DBI`/`DBD::Pg`.

```
cpanm --local-lib=local --installdeps .
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/carolina_dev \
CAROLINA_URL=http://127.0.0.1:4000 \
POLYGLOT_REGISTER_TOKEN=dev \
PUBLIC_BASE_URL=http://127.0.0.1:4006 \
PORT=4006 \
perl app.pl
```
