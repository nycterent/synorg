# Walking-skeleton stand-in image (see server.py). Stdlib-only python on
# alpine — same base family as the lending-controller image, no pip.
FROM alpine:3.20
RUN apk add --no-cache python3
COPY server.py /server.py
USER 65532
EXPOSE 8001
ENTRYPOINT ["python3", "/server.py"]
