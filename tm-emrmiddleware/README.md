# EMR Middleware — Docker Setup

Dockerized deployment of the [Intelehealth EMR Middleware](https://github.com/Intelehealth/intelehealth-middleware/tree/unicef-emr-middleware) (`unicef-emr-middleware` branch).

Built with **Java 8 + Maven**, deployed on **Tomcat 8.5**, exposed on **port 8999**.

---

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (v20+)
- [Docker Compose](https://docs.docker.com/compose/install/) (v2+)
- Network access to GitHub (the build stage clones the repo)
- A running MySQL instance (external — not included in this setup)

---

## Project Structure

```
tm-emrmiddleware/
├── Dockerfile              # Multi-stage build: Maven → Tomcat 8.5
├── docker-compose.yml      # Service definition; maps port 8999:8080
├── .env                    # Docker Compose env vars (safe to leave as-is)
├── .env.example            # Template for .env
└── config/
    ├── config.properties   # App config (host, ports, Treblle keys)
    └── db_properties.xml   # MyBatis DB connection & pool settings
```

---

## Quick Start

### 1. Configure the database

Edit `config/db_properties.xml` and replace the placeholders:

```xml
<property name="url"      value="jdbc:mysql://DB_HOST:DB_PORT/DB_NAME?autoReconnect=true&amp;useSSL=false&amp;serverTimezone=UTC"/>
<property name="username" value="DB_USERNAME"/>
<property name="password" value="DB_PASSWORD"/>
```

### 2. Configure the application

Edit `config/config.properties`:

```properties
MybatisEnvironmentId=intelehealthAwsTest   # must match <environment id> in db_properties.xml
serverhost=http://your-server-host
port=8080                                  # internal Tomcat port — do not change
mindmapPort=3004
swaggerhost=http://your-public-ip
treblle.apiKey=your-treblle-api-key        # leave blank to disable Treblle monitoring
treblle.projectId=your-treblle-project-id
```

### 3. Build and run

```bash
# Build the Docker image (clones GitHub repo, compiles WAR)
docker-compose build

# Start the container in the background
docker-compose up -d

# View logs
docker-compose logs -f

# Stop the container
docker-compose down
```

The application will be available at:

```
http://localhost:8999/
```

---

## Configuration Details

### How config files are applied

Config files in `config/` are **volume-mounted** into the running container at:

```
/usr/local/tomcat/webapps/ROOT/WEB-INF/classes/
```

This means you can update `config.properties` or `db_properties.xml` and restart the container **without rebuilding the image**:

```bash
docker-compose restart
```

### Port mapping

| Where | Port |
|---|---|
| Host (your machine) | **8999** |
| Container (Tomcat) | 8080 |

To change the host port, edit the `ports` entry in `docker-compose.yml`:

```yaml
ports:
  - "NEW_PORT:8080"
```

### MyBatis environment

The `MybatisEnvironmentId` in `config.properties` must exactly match the `id` attribute of an `<environment>` block in `db_properties.xml`. The default is `intelehealthAwsTest`.

---

## Useful Commands

```bash
# Rebuild after code changes on GitHub
docker-compose build --no-cache

# Start with logs in foreground
docker-compose up

# Check running containers
docker ps

# Open a shell inside the running container
docker exec -it emr-middleware bash

# Check Tomcat logs directly
docker exec -it emr-middleware tail -f /usr/local/tomcat/logs/catalina.out
```

---

## Troubleshooting

| Problem | What to check |
|---|---|
| Container exits immediately | Run `docker-compose logs` — likely a DB connection error or missing config file |
| `ClassNotFoundException: com.mysql.cj.jdbc.Driver` | Verify the MySQL JDBC driver is in `pom.xml` dependencies |
| Config changes not reflected | Make sure you restarted (`docker-compose restart`) after editing `config/` |
| Port 8999 already in use | Change the host port in `docker-compose.yml` or stop the conflicting process |
| Build fails at `git clone` | Check internet/GitHub access from the build machine |
| `db_properties.xml` mapper errors | Verify mapper resource paths match actual DMO XML file names in the source |

---

## Source Repository

- **Repo:** https://github.com/Intelehealth/intelehealth-middleware
- **Branch:** `unicef-emr-middleware`
- **Tech stack:** Java 8, Maven, Jersey (JAX-RS), MyBatis, MySQL, Logback
