FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive
ENV JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
ENV CATALINA_HOME=/opt/tomcat
ENV PATH=$JAVA_HOME/bin:$CATALINA_HOME/bin:$PATH

# Install JDK 8
RUN apt-get update && \
    apt-get install -y \
        openjdk-8-jdk \
        wget \
        curl \
        unzip \
        tzdata && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Verify Java
RUN java -version

# Install Tomcat 8.0.52
RUN wget -q https://archive.apache.org/dist/tomcat/tomcat-8/v8.0.52/bin/apache-tomcat-8.0.52.tar.gz \
        -O /tmp/tomcat.tar.gz && \
    tar -xzf /tmp/tomcat.tar.gz -C /opt/ && \
    mv /opt/apache-tomcat-8.0.52 /opt/tomcat && \
    rm /tmp/tomcat.tar.gz

# Remove default Tomcat webapps (security hardening)
RUN rm -rf $CATALINA_HOME/webapps/examples \
           $CATALINA_HOME/webapps/docs \
           $CATALINA_HOME/webapps/host-manager \
           $CATALINA_HOME/webapps/manager

# Download OpenMRS Core 2.1.4 WAR
RUN wget -q --tries=3 \
        https://mavenrepo.openmrs.org/nexus/content/repositories/public/org/openmrs/web/openmrs/2.1.4/openmrs-2.1.4.war \
        -O $CATALINA_HOME/webapps/openmrs.war

# Create OpenMRS data directory
RUN mkdir -p /opt/openmrs/data

# Set OpenMRS application data directory
ENV OPENMRS_APPLICATION_DATA_DIRECTORY=/opt/openmrs/data

# Copy startup script
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8080

CMD ["/start.sh"]
