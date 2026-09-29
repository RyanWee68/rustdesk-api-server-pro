FROM golang:alpine AS golang
WORKDIR /backend
ARG APP_VERSION=latest
ARG BUILD_TIME=""
ENV APP_VERSION=$APP_VERSION
ENV BUILD_TIME=$BUILD_TIME
COPY ./backend .
RUN go build -ldflags "-X main.appVersion=${APP_VERSION} -X main.buildTime=${BUILD_TIME}"


FROM node:20-alpine AS node
WORKDIR /frontend
ARG APP_VERSION=latest
ARG BUILD_TIME=""
ENV VITE_APP_VERSION=$APP_VERSION
ENV VITE_BUILD_TIME=$BUILD_TIME
COPY ./soybean-admin .
RUN rm -rf node_modules
RUN npm install -g pnpm
RUN pnpm install --frozen-lockfile && pnpm build

FROM alpine:3.20.3
ENV ADMIN_USER=test
ENV ADMIN_PASS=testadmin
ENV PORT=12345
ENV ADMIN_PORT=12346
ENV RUSTDESK_HBBS_DIR=
ARG APP_VERSION=latest
ARG BUILD_TIME=""
ENV APP_VERSION=$APP_VERSION
ENV BUILD_TIME=$BUILD_TIME
WORKDIR /app
COPY ./docker/start.sh .
COPY ./scripts/deploy/update-rustdesk-api.sh /usr/local/share/rustdesk-api-server-pro/update-container.sh
COPY --from=golang /backend/rustdesk-api-server-pro .
COPY --from=golang /backend/server.yaml .
COPY --from=node /frontend/dist ./dist
RUN apk add tzdata
EXPOSE 12345 12346
CMD [ "sh", "/app/start.sh"]
