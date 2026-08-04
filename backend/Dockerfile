FROM golang:1.26-alpine AS build

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/noikar-auth ./cmd/server

FROM alpine:3.22

RUN adduser -D -H -u 10001 app

USER app
COPY --from=build /out/noikar-auth /usr/local/bin/noikar-auth

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/noikar-auth"]
