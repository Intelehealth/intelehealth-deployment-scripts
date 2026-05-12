# Stage 1: Build — clone from GitHub and compile the WAR
FROM maven:3.8.6-openjdk-8 AS builder

RUN apt-get update && apt-get install -y git --no-install-recommends && rm -rf /var/lib/apt/lists/*

RUN git clone --branch unicef-emr-middleware --depth 1 \
    https://github.com/Intelehealth/intelehealth-middleware.git /src

WORKDIR /src/EMR-Middleware

RUN mvn clean package -DskipTests

# Stage 2: Runtime — Tomcat 8.5 + JDK 8
FROM tomcat:8.5-jdk8

# Remove default sample webapps
RUN rm -rf /usr/local/tomcat/webapps/*

# Deploy the WAR as ROOT context (accessible at /)
COPY --from=builder /src/EMR-Middleware/target/EMR-Middleware*.war \
     /usr/local/tomcat/webapps/ROOT.war

EXPOSE 8080

CMD ["catalina.sh", "run"]
