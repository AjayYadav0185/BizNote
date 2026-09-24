# ---- Stage 1: build the Flutter web app ----
FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app

# Resolve dependencies first so this layer is cached across source changes.
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

# Bring in the rest of the source.
COPY . .

# Regenerate the sqflite shared worker + sqlite3.wasm (required by the web app).
RUN dart run sqflite_common_ffi_web:setup

# Build the web release. It is served under the /app/ path, so base-href must match.
RUN flutter build web --release --base-href /app/

# ---- Stage 2: serve with nginx ----
FROM nginx:1.27-alpine

# - Extra MIME types (the APK download; wasm already ships in nginx 1.27's
#   mime.types). They must be inserted INSIDE the types { ... } block - the
#   file's last line is "}", so appending after it would put the entries in
#   http context and nginx would fail with: unknown directive "application/wasm".
#   Skip any type that is already present to avoid duplicates.
# - Drop the stock server block (our template regenerates conf.d/default.conf).
RUN set -eux; \
    extra=''; \
    grep -q 'application/wasm' /etc/nginx/mime.types \
      || extra="$extra    application/wasm wasm;\n"; \
    grep -q 'application/vnd.android.package-archive' /etc/nginx/mime.types \
      || extra="$extra    application/vnd.android.package-archive apk;\n"; \
    tail -1 /etc/nginx/mime.types | grep -qx '}'; \
    sed -i '$d' /etc/nginx/mime.types; \
    printf '%b' "$extra" >> /etc/nginx/mime.types; \
    printf '}\n' >> /etc/nginx/mime.types; \
    rm -f /etc/nginx/conf.d/default.conf

# Server config. ${PORT} is substituted at container start by the nginx
# entrypoint's envsubst (Render sets PORT, default 10000).
COPY nginx.conf.template /etc/nginx/templates/default.conf.template

# Landing page at "/", the built Flutter app at "/app/", and the APK at "/apk/".
COPY index.html /usr/share/nginx/html/index.html
COPY --from=build /app/build/web /usr/share/nginx/html/app
COPY apk/ /usr/share/nginx/html/apk/

# Fallback for local runs; Render overrides this with its own PORT.
ENV PORT=10000
EXPOSE 10000

# The default nginx entrypoint runs envsubst on /etc/nginx/templates, then
# execs this CMD.
CMD ["nginx", "-g", "daemon off;"]
