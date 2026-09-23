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

# Add the MIME types that Flutter's wasm and the APK download need, and drop
# the stock server block (our template regenerates conf.d/default.conf).
RUN printf 'application/wasm wasm;\napplication/vnd.android.package-archive apk;\n' \
      >> /etc/nginx/mime.types \
    && rm -f /etc/nginx/conf.d/default.conf

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
