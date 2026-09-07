FROM perl:5.40-bookworm
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates libpq-dev gcc libc6-dev make \
 && rm -rf /var/lib/apt/lists/*
