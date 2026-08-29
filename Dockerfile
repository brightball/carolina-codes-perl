FROM perl:5.40-slim
WORKDIR /app
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq-dev gcc libc6-dev make ca-certificates \
 && cpanm --notest HTTP::Daemon HTTP::Message HTTP::Tiny DBI DBD::Pg JSON URI \
 && apt-get purge -y gcc libc6-dev make \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* /root/.cpanm
COPY app.pl cpanfile ./
ENV PORT=8080
EXPOSE 8080
CMD ["perl", "app.pl"]
