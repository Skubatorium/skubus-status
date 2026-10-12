FROM alpine:3.20
RUN apk add --no-cache bash curl openssl bind-tools jq \
 && adduser -D -u 10001 checker \
 && mkdir -p /app /data && chown checker /data
COPY checker/check.sh /app/check.sh
COPY targets.json /app/targets.json
RUN chmod 755 /app/check.sh
USER checker
VOLUME /data
CMD ["/app/check.sh"]
