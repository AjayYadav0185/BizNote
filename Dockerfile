FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
RUN dart run sqflite_common_ffi_web:setup
RUN flutter build web --release --base-href /app/
FROM nginx:1.27-alpineRUN set -eux; \
    extra=''; \
    grep -q 'application/wasm' /etc/nginx/mime.types \
      || extra="$extra    application/wasm wasm;\n"; \
    grep -q 'application/vnd.android.package-archive' /etc/nginx/mime.types \
      || extra="$extra    application/vnd.android.package-archive apk;\n"; \
    tail -1 /etc/nginx/mime.types | grep -qx '}'; \
    sed -i '$d' /etc/nginx/mime.types; \
    printf '%b' "$extra" >> /etc/nginx/mime.types; \
    printf '}\n' >> /etc/nginx/mime.types; \
    rm -f /etc/nginx/conf.d/default.confCOPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY index.html /usr/share/nginx/html/index.html
COPY --from=build /app/build/web /usr/share/nginx/html/app
COPY apk/ /usr/share/nginx/html/apk/
ENV PORT=10000
EXPOSE 10000CMD ["nginx", "-g", "daemon off;"]
