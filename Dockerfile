# Build stage - compiles Java code inside Docker
FROM maven:3.9-eclipse-temurin-25 AS builder
WORKDIR /workspace
COPY . /workspace
RUN mvn clean package -DskipTests

# Runtime stage - runs the compiled application
FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=builder /workspace/target/urlaubsverwaltung-*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]