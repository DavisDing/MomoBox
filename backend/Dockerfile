# syntax=docker/dockerfile:1.7
FROM golang:1.22.8-alpine3.20 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
COPY migrations ./migrations
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/momo-backend ./cmd/momo-backend

FROM alpine:3.20.3
RUN addgroup -S momo && adduser -S -G momo -u 10001 momo \
    && apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=build /out/momo-backend /app/momo-backend
COPY --from=build /src/migrations /app/migrations
USER momo
EXPOSE 8080
ENTRYPOINT ["/app/momo-backend"]
CMD ["serve"]
