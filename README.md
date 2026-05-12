# Intelehealth Telemedicine — Sequential Deployment Guide

> Branch: `telemedkg` · Source: [intelehealth-deployment-scripts](https://github.com/Intelehealth/intelehealth-deployment-scripts/tree/telemedkg)

## Architecture Overview

```
Internet
   │
[Nginx + SSL (host)]
   │
   ├──► :8080  OpenMRS 2.1.4 (Tomcat in Docker)
   │              └──► MySQL 5.7 (Docker, localhost only)
   │
   ├──► :3004  Node.js Backend (Docker)
   │              └──► intelehealth-cron (Docker)
   │
   ├──► :8999  EMR Middleware (Tomcat/Java in Docker)
   │
   └──► :81    Angular Doctor Web App (Nginx in Docker)
```

All services run on a single AWS EC2 `t3a.large` instance (Ubuntu 22.04, Mumbai region).

---

## Prerequisites

| Tool | Min Version | Purpose |
|------|-------------|---------|
| Terraform | 1.3+ | Provision AWS EC2 |
| AWS CLI | 2.x | AWS authentication |
| SSH key pair | — | EC2 access (must exist in AWS) |
| A registered domain | — | SSL certificate via Let's Encrypt |

---

## Phase 1 — Provision Infrastructure (Local Machine)

> **Directory:** `tm-iac/`

### 1.1 Configure AWS credentials

```bash
aws configure
# Enter: Access Key ID, Secret Access Key, region: ap-south-1, output: json
```

### 1.2 Initialise Terraform

```bash
cd tm-iac
terraform init
```

### 1.3 Review and apply

```bash
terraform plan \
  -var="key_pair_name=<YOUR_KEY_PAIR_NAME>" \
  -var="allowed_ssh_cidr=<YOUR_IP>/32"

terraform apply \
  -var="key_pair_name=<YOUR_KEY_PAIR_NAME>" \
  -var="allowed_ssh_cidr=<YOUR_IP>/32"
```

> **Important — Security hardening before apply:**
> The default `main.tf` opens MySQL port 3306 to `0.0.0.0/0`.  
> Always override `allowed_ssh_cidr` to your own IP.  
> Consider removing the 3306 ingress rule entirely — MySQL should only be accessed internally.

### 1.4 Note the outputs

```
instance_id  = i-xxxxxxxxxxxxxxxxx
elastic_ip   = <PUBLIC_IP>
public_dns   = ec2-xxx.ap-south-1.compute.amazonaws.com
```

Point your domain's A record to `elastic_ip` before continuing.

---

## Phase 2 — Server Bootstrap (SSH into EC2)

```bash
ssh -i ~/.ssh/<YOUR_KEY>.pem ubuntu@<elastic_ip>
```

### 2.1 Update system packages

```bash
sudo apt-get update && sudo apt-get upgrade -y
```

### 2.2 Create a non-root deployment user (recommended)

```bash
sudo useradd -m -s /bin/bash deploy
sudo usermod -aG sudo deploy
sudo su - deploy
```

---

## Phase 3 — Deploy OpenMRS (EMR Core)

> **Directory on server:** `tm-install-guide/`  
> **Script:** `setup-files/setup.sh`

This is the most time-consuming step. OpenMRS first-boot takes **5–15 minutes**.

### 3.1 Copy setup files to server

```bash
# From local machine
scp -r -i ~/.ssh/<KEY>.pem tm-install-guide/ ubuntu@<elastic_ip>:~/
```

### 3.2 Create the credentials file

```bash
cd ~/tm-install-guide/setup-files
cp .env.example .env     # if provided, otherwise create manually
nano .env
```

Minimum required variables:

```env
DB_PASSWORD=<strong_password>
DB_ROOT_PASSWORD=<strong_root_password>
```

### 3.3 Run the automated installer

```bash
chmod +x setup.sh

# With SSL (recommended for production)
sudo ./setup.sh --domain your.domain.com --email admin@your-org.org

# Without SSL (dev/testing only)
sudo ./setup.sh --domain your.domain.com --no-ssl

# If Docker is already installed
sudo ./setup.sh --domain your.domain.com --email admin@your-org.org --skip-docker
```

The script performs these steps automatically:
1. Installs nginx, snapd, Docker dependencies
2. Configures rootless Docker with systemd session
3. Sets Docker log rotation (50 MB / ~3-day retention)
4. Creates `/opt/openmrs/` directory structure
5. Downloads OpenMRS Reference Application 2.8.0
6. Starts MySQL 5.7 + OpenMRS via Docker Compose
7. Configures nginx reverse proxy (HTTP → 8080)
8. Provisions Let's Encrypt SSL certificate via Certbot

### 3.4 Verify OpenMRS is running

```bash
docker ps | grep openmrs
# Wait until status shows "healthy"

curl -I http://127.0.0.1:8080/openmrs
# Expect: HTTP/1.1 200 or 302
```

> OpenMRS is now accessible at `https://your.domain.com/openmrs`  
> Default credentials: `admin` / `Admin123` — **change immediately**.

---

## Phase 4 — Deploy Backend Microservices

> **Directory:** `tm-microservices/`

The backend is a Node.js app cloned from `intelehealth-backend` (branch: `unicef_krygz_dev_master`). A separate cron container runs scheduled jobs.

### 4.1 Copy files to server

```bash
scp -r -i ~/.ssh/<KEY>.pem tm-microservices/ ubuntu@<elastic_ip>:~/
```

### 4.2 Create the `.env` file

```bash
cd ~/tm-microservices
nano .env
```

Required environment variables (check the application's own docs for the full list):

```env
PORT=3004
DB_HOST=<RDS_or_localhost>
DB_PORT=3306
DB_NAME=intelehealth
DB_USER=<db_user>
DB_PASSWORD=<db_password>
NODE_ENV=production
# Add any other app-specific secrets here
```

### 4.3 Build and start

```bash
docker compose build
docker compose up -d
```

This starts two containers:
- `intelehealth-backend` — main API server on port 3004
- `intelehealth-cron` — background job runner (depends on `app`)

### 4.4 Verify

```bash
docker ps | grep intelehealth-backend
docker logs intelehealth-backend --tail 50
curl http://127.0.0.1:3004/
```

---

## Phase 5 — Deploy EMR Middleware

> **Directory:** `tm-emrmiddleware/`

Java-based REST middleware (Jersey + MyBatis) running on Tomcat 8.5, exposed on port 8999.  
Build time: **5–10 minutes** (Maven compiles from source).

### 5.1 Copy files to server

```bash
scp -r -i ~/.ssh/<KEY>.pem tm-emrmiddleware/ ubuntu@<elastic_ip>:~/
```

### 5.2 Configure database connection

Edit `config/db_properties.xml`:

```xml
<property name="url" value="jdbc:mysql://<DB_HOST>:<DB_PORT>/<DB_NAME>"/>
<property name="username" value="<DB_USER>"/>
<property name="password" value="<DB_PASSWORD>"/>
```

Replace `<DB_HOST>`, `<DB_PORT>`, `<DB_NAME>`, `<DB_USER>`, `<DB_PASSWORD>` with actual values.  
If OpenMRS MySQL is running locally: `<DB_HOST>` = `172.17.0.1` (Docker bridge gateway) or the container IP.

### 5.3 Configure application properties

Edit `config/config.properties`:

```properties
serverhost=https://your.domain.com
port=8999
mindmapPort=3004

# Optional: Treblle API observability
treblleApiKey=<your_key>
treblleProjectId=<your_project>
```

### 5.4 Create `.env` file

```bash
cd ~/tm-emrmiddleware
nano .env
# Add any environment variables expected by the middleware
```

### 5.5 Build and start

```bash
docker compose build    # Maven build — takes several minutes
docker compose up -d
```

### 5.6 Verify

```bash
docker ps | grep emr-middleware
docker logs emr-middleware --tail 50

curl -I http://127.0.0.1:8999/
# Expect: HTTP/1.1 200
```

---

## Phase 6 — Deploy Doctor Web Application

> **Directory:** `tm-webapp/`

Angular app built from `intelehealth-doctor-webapp` (branch: `unicef_krygz_dev_master`), served by Nginx on port 81.  
Build time: **5–10 minutes** (Angular AOT compilation).

### 6.1 Copy files to server

```bash
scp -r -i ~/.ssh/<KEY>.pem tm-webapp/ ubuntu@<elastic_ip>:~/
```

### 6.2 Build and start

```bash
cd ~/tm-webapp
docker compose build
docker compose up -d
```

### 6.3 Verify

```bash
docker ps | grep intelehealth-webapp
curl -I http://127.0.0.1:81/
# Expect: HTTP/1.1 200
```

---

## Phase 7 — Configure Nginx Routing (Optional)

If you want all services accessible under a single domain with path-based routing, add a server block or extend the existing nginx config on the host:

```nginx
# /etc/nginx/conf.d/intelehealth.conf

# Backend API
location /api/ {
    proxy_pass http://127.0.0.1:3004/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}

# EMR Middleware
location /middleware/ {
    proxy_pass http://127.0.0.1:8999/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}

# Doctor Web App
location /app/ {
    proxy_pass http://127.0.0.1:81/;
    proxy_set_header Host $host;
}
```

Reload nginx after changes:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

## Post-Deployment Checklist

- [ ] Change OpenMRS default admin password
- [ ] Rotate all `.env` secrets (never commit to git)
- [ ] Restrict MySQL port 3306 in the AWS Security Group to internal CIDR only
- [ ] Restrict SSH (port 22) to your IP only via `allowed_ssh_cidr`
- [ ] Confirm Certbot auto-renewal: `sudo certbot renew --dry-run`
- [ ] Verify HSTS header is present: `curl -I https://your.domain.com | grep Strict`
- [ ] Set up CloudWatch or a log aggregator for container logs
- [ ] Schedule regular EBS snapshots for the EC2 root volume

---

## Service Port Reference

| Service | Internal Port | External Port | Notes |
|---------|--------------|---------------|-------|
| OpenMRS (Tomcat) | 8080 | via nginx :80/:443 | localhost-bound only |
| MySQL | 3306 | localhost only | never expose publicly |
| Node.js Backend | 3004 | 3004 | add nginx proxy for SSL |
| Node.js Cron | — | none | internal only |
| EMR Middleware (Tomcat) | 8080 | 8999 | add nginx proxy for SSL |
| Doctor Web App (Nginx) | 80 | 81 | add nginx proxy for SSL |

---

## Troubleshooting

### OpenMRS not starting
```bash
docker logs openmrs --tail 100
# Check for DB_PASSWORD mismatch or insufficient memory (needs ≥1.5 GB free)
```

### Backend container exits immediately
```bash
docker logs intelehealth-backend
# Usually a missing .env variable or unreachable database
```

### EMR Middleware build fails
```bash
docker logs emr-middleware
# Maven dependency issues — check internet connectivity from the EC2 instance
# Alternatively, pre-build the image locally and push to a registry
```

### Port conflicts
```bash
sudo ss -tlnp | grep -E '3004|8999|81|8080'
# Kill or reconfigure any conflicting processes
```

### SSL certificate renewal failure
```bash
sudo certbot certificates          # Check expiry date
sudo certbot renew --force-renewal # Force renewal
```

---

## Destroy Infrastructure (Cleanup)

```bash
# From local machine, in tm-iac/
terraform destroy \
  -var="key_pair_name=<YOUR_KEY_PAIR_NAME>"
```

> This permanently deletes the EC2 instance and Elastic IP. Back up all data first.
