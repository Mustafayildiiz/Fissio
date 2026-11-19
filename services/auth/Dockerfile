FROM golang:1.25-alpine AS build
WORKDIR /src
# Bağımlılıklar kaynak koddan ayrı katmanda: kod değişince yeniden indirilmez
COPY go.mod go.sum ./
RUN for i in 1 2 3 4 5; do go mod download && exit 0; echo "go mod download denemesi $i basarisiz"; sleep 5; done; exit 1
COPY . .
RUN CGO_ENABLED=0 go build -o /app .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates && adduser -D -u 10001 app
COPY --from=build /app /app
USER app
EXPOSE 8080
CMD ["/app"]
