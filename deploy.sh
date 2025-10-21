#!/bin/sh
set -eu

# === CONFIGURATION ===
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
error_exit() { log " ERROR: $*"; exit 1; }

trap 'error_exit "Script exited unexpectedly."' EXIT

# === COLLECT PARAMETERS ===
printf "Enter Git repository URL: "
read GIT_REPO
[ -z "$GIT_REPO" ] && error_exit "Repository URL cannot be empty."

printf "Enter Personal Access Token (PAT): "
read PAT
[ -z "$PAT" ] && error_exit "PAT cannot be empty."

printf "Enter branch name (default: main): "
read BRANCH
[ -z "$BRANCH" ] && BRANCH="main"

printf "Enter remote SSH username: "
read REMOTE_USER
[ -z "$REMOTE_USER" ] && error_exit "Username cannot be empty."

printf "Enter remote server IP address: "
read SERVER_IP
[ -z "$SERVER_IP" ] && error_exit "Server IP cannot be empty."

printf "Enter SSH key path: "
read SSH_KEY
[ ! -f "$SSH_KEY" ] && error_exit "SSH key not found at: $SSH_KEY"

printf "Enter application internal port (e.g. 5000): "
read APP_PORT
[ -z "$APP_PORT" ] && error_exit "App port cannot be empty."

printf "Enter domain name (press Enter to use server IP): "
read DOMAIN

# Use server IP if no domain entered
if [ -z "$DOMAIN" ]; then
    log "No domain entered. Detecting server public IP..."
    DOMAIN=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE_USER@$SERVER_IP" "curl -s ifconfig.me || hostname -I | awk '{print \$1}'")
    [ -z "$DOMAIN" ] && DOMAIN="$SERVER_IP"
    log "Using server IP as domain: $DOMAIN"
else
    log "Using provided domain: $DOMAIN"
fi

# === CLONE OR UPDATE REPO LOCALLY ===
REPO_DIR=$(basename "$GIT_REPO" .git)

if [ -d "$REPO_DIR" ]; then
    log "Repository exists. Pulling latest changes..."
    cd "$REPO_DIR"
    git pull origin "$BRANCH" || error_exit "Failed to pull latest changes."
else
    log "Cloning repository..."
    git clone -b "$BRANCH" "https://${PAT}@${GIT_REPO#https://}" || error_exit "Git clone failed."
    cd "$REPO_DIR"
fi

[ ! -f "dockerfile" ] && error_exit "dockerfile not found in repository."
log " Repository ready."

# === REMOTE DEPLOYMENT ===
log "Deploying application and configuring server..."

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE_USER@$SERVER_IP" <<REMOTE_EOF
set -eu

# Update & install packages
sudo yum update -y
sudo yum install -y docker nginx
sudo systemctl enable --now docker nginx
sudo usermod -aG docker $USER || true

# Prepare app directory
mkdir -p /home/$USER/app
cd /home/$USER/app

# Copy files from local repo
exit_status=\$(scp -i "$SSH_KEY" -r $(pwd)/* "$USER@$SERVER_IP:/home/$USER/app/" 2>/dev/null || true)
# NOTE: If copying locally via script, scp needs to be run from local machine.

# Clean up old containers/images
docker stop myapp 2>/dev/null || true
docker rm myapp 2>/dev/null || true
docker rmi myapp:latest 2>/dev/null || true

# Build & run Docker container
docker build -t myapp .
docker run -d --name myapp -p $APP_PORT:$APP_PORT myapp

# Configure Nginx reverse proxy
sudo tee /etc/nginx/conf.d/myapp.conf > /dev/null <<NGINX_CONF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX_CONF

sudo nginx -t
sudo systemctl reload nginx

# Internal validation
curl -I http://localhost:$APP_PORT || echo "Warning: App not responding internally"
REMOTE_EOF

log "Deployment complete! Access your app at http://$DOMAIN"

# === CLEANUP FLAG ===
if [ "${1:-}" = "--cleanup" ]; then
    log "Cleaning up deployment..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE_USER@$SERVER_IP" <<CLEANUP_EOF
set -eu
docker stop myapp 2>/dev/null || true
docker rm myapp 2>/dev/null || true
sudo rm -rf /home/$USER/app /etc/nginx/conf.d/myapp.conf
sudo systemctl reload nginx
CLEANUP_EOF
    log "Cleanup completed."
fi

log "Deployment log saved to $LOG_FILE."
