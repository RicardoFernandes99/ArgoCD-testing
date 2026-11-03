FROM node:24-alpine

# Links the image in GHCR to this repository.
LABEL org.opencontainers.image.source="https://github.com/RicardoFernandes99/ArgoCD-testing"

WORKDIR /app
COPY server.js .

# Set by CI to the commit that was built.
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    PORT=8080

# The image's built-in "node" user (non-root).
USER 1000
EXPOSE 8080
CMD ["node", "server.js"]
