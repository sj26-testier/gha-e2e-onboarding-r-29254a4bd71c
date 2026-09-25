FROM alpine:3.20
RUN echo "probe built at $(date -u +%FT%TZ)" > /probe.txt && sleep 2
CMD ["cat", "/probe.txt"]
