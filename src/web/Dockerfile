FROM nginx:1.27-alpine

# Links the image in GHCR to this repository.
LABEL org.opencontainers.image.source="https://github.com/RicardoFernandes99/ArgoCD-testing"

# Set by CI to the commit that was built, and shown on the page.
ARG APP_VERSION=dev

# The image renders templates/*.template into conf.d/ at start (envsubst).
ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY index.html /usr/share/nginx/html/index.html
RUN sed -i "s/__APP_VERSION__/${APP_VERSION}/g" /usr/share/nginx/html/index.html
