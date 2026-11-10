# syntax=docker/dockerfile:1.7
FROM golang:1.22.8-alpine3.20@sha256:f56a8a4a1aea41bc4694728b69c219af1523aea15690cbbed82dc9bac81e6603 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
COPY migrations ./migrations
ARG APP_VERSION=dev
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w -X github.com/momobox/backend/internal/platform.DefaultAppVersion=${APP_VERSION}" -o /out/momo-backend ./cmd/momo-backend

FROM alpine:3.20.3@sha256:1e42bbe2508154c9126d48c2b8a75420c3544343bf86fd041fb7527e017a4b4a
RUN apk add --no-cache ca-certificates tzdata tesseract-ocr tesseract-ocr-data-eng tesseract-ocr-data-chi_sim \
    && mkdir -p /data && chmod 0700 /data
ENV APP_ENV=production TMPDIR=/tmp
WORKDIR /app
COPY --from=build /out/momo-backend /app/momo-backend
COPY --from=build /src/migrations /app/migrations
USER root
EXPOSE 8080
ENTRYPOINT ["/app/momo-backend"]
CMD ["serve"]
