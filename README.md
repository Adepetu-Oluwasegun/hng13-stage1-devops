# hng13-stage1-devops

# Flask Docker Deployment with Nginx Reverse Proxy

## Overview
This project demonstrates how to deploy a **Flask application** inside a **Docker container** on a remote Linux server, with **Nginx configured as a reverse proxy** to forward HTTP traffic to the container. The deployment is automated via a **bash script**.

---

## Features
- Automatically clones or updates a Git repository.
- Installs Docker and Nginx on the remote server if not present.
- Builds a Docker image from the repository and runs the Flask app.
- Configures Nginx as a reverse proxy to forward port 80 traffic to the container’s internal port.
- Validates deployment and ensures the app is accessible via server IP or domain.
- Optional cleanup to remove the app, Docker containers, and Nginx configuration.

---

## Prerequisites
- Remote Linux server (Amazon Linux, Ubuntu, etc.)
- SSH access (`ec2-user` or other user)
- Git repository containing:
  - `app.py` (Flask app)
  - `requirements.txt`
  - `dockerfile`
  - `docker-compose.yml` (optional)
- Local machine with internet access

---

## Deployment Script


### Make Script Executable
```bash
chmod +x deploy.sh
