# ArtTrust curator web portal — container image.
# Build context is the REPO ROOT (the portal depends on the SDK via a relative
# file: path), e.g.:  docker build -f consumers/arttrust/web-portal/Dockerfile .
FROM node:20-alpine AS build
WORKDIR /repo

# Build the web SDK the portal links against (file: dependency).
COPY sdk/ts/dna424-client /repo/sdk/ts/dna424-client
RUN cd sdk/ts/dna424-client && npm install && npm run build

# Build the portal's static bundle (Vite -> dist-web/, SDK inlined).
# VITE_API_BASE bakes the domain-API base URL (cloud deploys pass the Cloud Run URL).
ARG VITE_API_BASE=""
ENV VITE_API_BASE=$VITE_API_BASE
COPY consumers/arttrust/web-portal /repo/consumers/arttrust/web-portal
RUN cd consumers/arttrust/web-portal && npm install && npm run build

# Serve the static bundle with nginx.
FROM nginx:alpine
COPY --from=build /repo/consumers/arttrust/web-portal/dist-web /usr/share/nginx/html
EXPOSE 80
# The page calls AttestCore from the BROWSER (default http://localhost:8080,
# editable in the UI), so the web container needs no link to the api container.
