# AWS EC2 Terraform — Ubuntu 22.04 / Mumbai

Provisions a single `t3a.large` EC2 instance in **ap-south-1 (Mumbai)** running **Ubuntu 22.04 LTS**, with a static Elastic IP and a security group exposing the required ports.

---

## Resources

| Resource | Details |
|---|---|
| EC2 Instance | `t3a.large`, Ubuntu 22.04 LTS (latest Canonical AMI) |
| Region | `ap-south-1` — Mumbai |
| Root Volume | 30 GiB gp3, encrypted, deleted on termination |
| Elastic IP | Static public IP, survives instance restarts |
| Security Group | Ports 22, 80, 443, 3004, 9090, 3306 |
| IMDSv2 | Enforced (security best practice) |

---

## Open Ports

| Port | Protocol | Purpose |
|---|---|---|
| 22 | TCP | SSH |
| 80 | TCP | HTTP |
| 443 | TCP | HTTPS |
| 3004 | TCP | Application |
| 9090 | TCP | Prometheus / Monitoring |
| 3306 | TCP | MySQL / MariaDB ⚠️ |

> **Warning:** Port 3306 is open to `0.0.0.0/0` by default. Restrict it to a known CIDR before going to production (see [Security Hardening](#security-hardening) below).

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.3.0
- AWS CLI configured with credentials that have EC2/VPC permissions
- An existing **EC2 Key Pair** in `ap-south-1`

---

## Usage

### 1. Initialise

```bash
terraform init
```

### 2. Preview the plan

```bash
terraform plan -var="key_pair_name=YOUR_KEY_PAIR_NAME"
```

### 3. Apply

```bash
terraform apply -var="key_pair_name=YOUR_KEY_PAIR_NAME"
```

Once complete, Terraform prints the instance ID, public IP, and DNS.

### 4. SSH into the server

```bash
ssh -i ~/.ssh/YOUR_KEY.pem ubuntu@<public_ip>
```

### 5. Destroy (when no longer needed)

```bash
terraform destroy -var="key_pair_name=YOUR_KEY_PAIR_NAME"
```

---

## Variables

| Variable | Description | Default |
|---|---|---|
| `key_pair_name` | **Required.** Name of an existing EC2 Key Pair | — |
| `allowed_ssh_cidr` | CIDR allowed to reach port 22 | `0.0.0.0/0` |
| `instance_name` | Name tag applied to all resources | `intelehealth-server` |

Pass variables on the command line or create a `terraform.tfvars` file:

```hcl
# terraform.tfvars
key_pair_name    = "my-mumbai-key"
allowed_ssh_cidr = "203.0.113.10/32"
instance_name    = "intelehealth-server"
```

---

## Outputs

| Output | Description |
|---|---|
| `instance_id` | EC2 Instance ID |
| `public_ip` | Static Elastic IP address |
| `public_dns` | Public DNS hostname |
| `ami_used` | Ubuntu 22.04 AMI ID resolved at apply time |

---

## Security Hardening

Before deploying to production, consider the following:

**Restrict SSH access**
Limit port 22 to your office or VPN IP instead of the whole internet:
```hcl
allowed_ssh_cidr = "203.0.113.10/32"
```

**Restrict MySQL (port 3306)**
Never expose MySQL publicly if avoidable. Options:
- Set the ingress CIDR to your application server's IP only
- Move the DB to RDS inside a private subnet with no public access
- Access via SSH tunnel: `ssh -L 3306:localhost:3306 ubuntu@<public_ip>`

**Use a VPC with private subnets**
For a production setup, place the instance inside a custom VPC with public/private subnet separation and a NAT gateway for outbound traffic.

**Enable automated backups**
Add an EBS snapshot lifecycle policy or enable AWS Backup for the root volume.

---

## File Structure

```
.
├── main.tf       # All Terraform resources
└── README.md     # This file
```

---

## License

MIT
