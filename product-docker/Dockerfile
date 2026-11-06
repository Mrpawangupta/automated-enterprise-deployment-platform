# Multi-stage, multi-target Dockerfile for all three product components
# (matches the 3-container architecture in docs/architecture.md, kept as a
# single Dockerfile per the product-docker/ layout). Build a specific
# component with `--target`:
#   docker build --target api            -t analytics-api .
#   docker build --target webapp         -t analytics-web .
#   docker build --target data-processor -t analytics-data-processor .
# See build-scripts/ for wrappers around these commands.

# ---- shared base for the two JVM components ----
FROM eclipse-temurin:11-jre AS jvm-base
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
RUN groupadd -g 1001 appgroup && useradd -r -u 1001 -g appgroup appuser
WORKDIR /app

# ---- api target ----
FROM jvm-base AS api
COPY target/analytics-api-*.jar app.jar
COPY application-prod.yml config/
RUN chown -R appuser:appgroup /app
USER appuser
EXPOSE 8080
ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -XX:+UseG1GC"
ENTRYPOINT ["sh", "-c", "java ${JAVA_OPTS} -jar app.jar --spring.config.location=file:/app/config/"]

# ---- data-processor target ----
FROM jvm-base AS data-processor
COPY target/analytics-data-processor-*.jar app.jar
RUN chown -R appuser:appgroup /app
USER appuser
ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"
ENTRYPOINT ["sh", "-c", "java ${JAVA_OPTS} -jar app.jar"]

# ---- webapp target (static nginx, no JVM) ----
FROM nginx:1.27-alpine AS webapp
RUN addgroup -g 1001 -S appgroup && adduser -S appuser -u 1001 -G appgroup
COPY nginx.conf /etc/nginx/nginx.conf
COPY mime.types /etc/nginx/mime.types
COPY dist/ /usr/share/nginx/html/
RUN rm -f /etc/nginx/conf.d/default.conf && \
    chown -R appuser:appgroup /usr/share/nginx/html && \
    chmod -R 755 /usr/share/nginx/html
USER appuser
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1
CMD ["nginx", "-g", "daemon off;"]
