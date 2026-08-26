# Incus simple-streams image server
# Serves the static tree produced by scripts/generate-streams.py over HTTP.
# The web root is /usr/share/nginx/html; mount your generated `www` dir there.

FROM nginx:alpine

# Disable nginx default site, use our config
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/incus-streams.conf

EXPOSE 8080

# `www` is expected to be provided at runtime via a volume mount:
#   docker run -v $(pwd)/www:/usr/share/nginx/html:ro -p 8080:8080 ...
# (see docker-compose.yml)
CMD ["nginx", "-g", "daemon off;"]
