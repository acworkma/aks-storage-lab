# Multi-stage Dockerfile for Scala AKS Storage Lab
# Stage 1: Build the application with sbt
FROM sbtscala/scala-sbt:eclipse-temurin-jammy-21.0.1_12_1.9.7_3.3.1 AS builder

WORKDIR /app

# Copy build files
COPY build.sbt .
COPY project ./project

# Download dependencies (cached layer)
RUN sbt update

# Copy source code
COPY src ./src

# Build fat JAR
RUN sbt assembly

# Stage 2: Runtime image with Microsoft OpenJDK
FROM mcr.microsoft.com/openjdk/jdk:21-mariner

WORKDIR /app

# Copy the assembled JAR from builder stage
COPY --from=builder /app/target/scala-3.3.1/aks-storage-app.jar /app/aks-storage-app.jar

# Create non-root user
RUN groupadd -r appuser && useradd -r -g appuser appuser
RUN chown -R appuser:appuser /app
USER appuser

# Expose application port
EXPOSE 8080

# Set JVM options for container environment
ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -Djava.security.egd=file:/dev/./urandom"

# Run the application
CMD ["sh", "-c", "java $JAVA_OPTS -jar aks-storage-app.jar"]
