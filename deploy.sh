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
# read PAT without echoing to avoid leaking it on the terminal
stty -echo
read PAT
stty echo
printf "\n"
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

# Default non-interactive SSH/SCP options (defined early so they're always available)
# -T disables pseudo-tty allocation; BatchMode prevents password prompts; ConnectTimeout keeps attempts short
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o BatchMode=yes -T"
SCP_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"

printf "Enter application internal port (e.g. 80 or 8080): "
read APP_PORT
[ -z "$APP_PORT" ] && error_exit "App port cannot be empty."

printf "Enter domain name (press Enter to use server IP): "
read DOMAIN

# If no domain entered, allow  use of server IP
if [ -z "$DOMAIN" ]; then
    log "No domain entered. Detecting server public IP..."
    # Before attempting remote commands, verify SSH connectivity (fail fast with retries)
    SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o BatchMode=yes -T"
    SCP_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"

    attempt=0
    max_attempts=3
    while :; do
        attempt=$((attempt+1))
        log "Checking SSH connectivity to $REMOTE_USER@$SERVER_IP (attempt $attempt/$max_attempts)..."
        if ssh $SSH_OPTS "$REMOTE_USER@$SERVER_IP" 'echo SSH_OK' >/dev/null 2>&1; then
            log "SSH connectivity OK."
            break
        fi
        log "SSH connection attempt $attempt failed."
        if [ "$attempt" -ge "$max_attempts" ]; then
            error_exit "Cannot connect to $REMOTE_USER@$SERVER_IP via SSH after $max_attempts attempts. Check network, IP, security groups, and sshd on remote."
        fi
        sleep $((attempt * 2))
    done

    DOMAIN=$(ssh $SSH_OPTS "$REMOTE_USER@$SERVER_IP" "curl -s ifconfig.me || hostname -I | awk '{print \$1}'")
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
ssh $SSH_OPTS "$REMOTE_USER@$SERVER_IP" <<EOF
set -eu
sudo yum update -y
sudo yum install -y docker nginx
sudo systemctl enable --now docker nginx
sudo usermod -aG docker $REMOTE_USER || true
EOF
log " Remote server setup complete."
# === STEP 4: DEPLOY APPLICATION ===
log " Deploying Dockerized app to remote server..."
ssh $SSH_OPTS "$REMOTE_USER@$SERVER_IP" "mkdir -p /home/$REMOTE_USER/app"
scp $SCP_OPTS -r app.py requirements.txt dockerfile docker-compose.yml "$REMOTE_USER@$SERVER_IP:/home/$REMOTE_USER/app/"

ssh $SSH_OPTS "$REMOTE_USER@$SERVER_IP" <<EOF
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
ssh $SSH_OPTS "$REMOTE_USER@$SERVER_IP" <<EOF
sudo bash -c 'cat > /etc/nginx/conf.d/myapp.conf <<CONFIG
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
CONFIG'

sudo nginx -t && sudo systemctl reload nginx

EOF
log " Nginx configured to forward traffic to Docker app."

# === STEP 6: VALIDATION ===
log " Validating deployment..."
ssh $SSH_OPTS "$REMOTE_USER@$SERVER_IP" "curl -I http://localhost:$APP_PORT" || error_exit "App not responding internally."
curl -I "http://$DOMAIN" || error_exit "App not reachable via Nginx."
log " Deployment successful! Access your app at: http://$DOMAIN"

# === OPTIONAL CLEANUP FLAG ===
if [ "${1:-}" = "--cleanup" ]; then
    log " Cleaning up deployment..."
    ssh $SSH_OPTS "$REMOTE_USER@$SERVER_IP" <<EOF
docker stop myapp 2>/dev/null || true
docker rm myapp 2>/dev/null || true
sudo rm -rf /home/$REMOTE_USER/app /etc/nginx/conf.d/myapp.conf
sudo systemctl reload nginx
EOF
    log " Cleanup completed."
fi
log "Deployment log saved to $LOG_FILE."