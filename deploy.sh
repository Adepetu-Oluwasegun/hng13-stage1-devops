#!/bin/sh
set -eu

# === CONFIGURATION ===
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
error_exit() { log " ERROR: $*"; exit 1; }

trap 'error_exit "Script exited unexpectedly."' EXIT

# === STEP 1: COLLECT PARAMETERS ===
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

printf "Enter application internal port (e.g. 5000 or 8080): "
read APP_PORT
[ -z "$APP_PORT" ] && error_exit "App port cannot be empty."

printf "Enter domain name (press Enter to use server IP): "
read DOMAIN

# If no domain entered, allow  use of server IP
if [ -z "$DOMAIN" ]; then
    log "No domain entered. Detecting server public IP..."
    DOMAIN=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE_USER@$SERVER_IP" "curl -s ifconfig.me || hostname -I | awk '{print \$1}'")
    [ -z "$DOMAIN" ] && DOMAIN="$SERVER_IP"
    log "Using server IP as domain: $DOMAIN"
else
    log "Using provided domain: $DOMAIN"
fi

# === STEP 2: CLONE OR UPDATE REPO LOCALLY ===
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

# === STEP 3: PREPARE REMOTE SERVER ===
log " Preparing remote environment..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE_USER@$SERVER_IP" <<EOF
set -eu
sudo yum update -y
sudo yum install -y docker nginx
sudo systemctl enable --now docker nginx
sudo usermod -aG docker $REMOTE_USER || true
EOF
log " Remote server setup complete."

# === STEP 4: DEPLOY APPLICATION ===
log " Deploying Dockerized app to remote server..."
ssh -i "$SSH_KEY" "$REMOTE_USER@$SERVER_IP" "mkdir -p /home/$REMOTE_USER/app"
scp -i "$SSH_KEY" -r app.py requirements.txt dockerfile docker-compose.yml "$REMOTE_USER@$SERVER_IP:/home/$REMOTE_USER/app/"

ssh -i "$SSH_KEY" "$REMOTE_USER@$SERVER_IP" <<EOF
set -eu
cd /home/$REMOTE_USER/app

# Clean up old containers/images
docker stop myapp 2>/dev/null || true
docker rm myapp 2>/dev/null || true
docker rmi myapp:latest 2>/dev/null || true

# Build and run
docker build -t myapp .
docker run -d --name myapp -p $APP_PORT:$APP_PORT myapp

EOF
log " Docker container deployed."

# === STEP 5: CONFIGURE NGINX ===
log " Configuring Nginx reverse proxy..."
ssh -i "$SSH_KEY" "$REMOTE_USER@$SERVER_IP" <<'EOF'
sudo tee /etc/nginx/conf.d/myapp.conf > /dev/null <<NGINX_CONF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX_CONF

sudo nginx -t
sudo systemctl reload nginx
EOF

log " Nginx configured to forward traffic to Docker app."

# === STEP 6: VALIDATION ===
log " Validating deployment..."
ssh -i "$SSH_KEY" "$REMOTE_USER@$SERVER_IP" "curl -I http://localhost:$APP_PORT" || error_exit "App not responding internally."
curl -I "http://$DOMAIN" || error_exit "App not reachable via Nginx."
log " Deployment successful! Access your app at: http://$DOMAIN"

# === CLEANUP FLAG ===
if [ "${1:-}" = "--cleanup" ]; then
    log " Cleaning up deployment..."
    ssh -i "$SSH_KEY" "$REMOTE_USER@$SERVER_IP" <<EOF
docker stop myapp 2>/dev/null || true
docker rm myapp 2>/dev/null || true
sudo rm -rf /home/$REMOTE_USER/app /etc/nginx/conf.d/myapp.conf
sudo systemctl reload nginx
EOF
    log " Cleanup completed."
fi
log "Deployment log saved to $LOG_FILE."