FROM nginx:1.27-alpine

# Links the image in GHCR to this repository.
LABEL org.opencontainers.image.source="https://github.com/RicardoFernandes99/ArgoCD-testing"

# Set by CI to the commit that was built, and shown on the page.
ARG APP_VERSION=dev

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
RUN sed -i "s/__APP_VERSION__/${APP_VERSION}/g" /usr/share/nginx/html/index.html
