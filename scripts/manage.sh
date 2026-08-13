#!/bin/bash

# Configuration
APP_DIR="/home/user/media-gallery"
PID_FILE="$APP_DIR/app.pid"
LOG_FILE="$APP_DIR/logs/app.log"

start() {
    if [ -f "$PID_FILE" ]; then
        echo "App is already running (PID: $(cat $PID_FILE))"
        return
    fi
    echo "Starting Gallery App..."
    cd "$APP_DIR"
    export ADMIN_PASSWORD_HASH=$(cat "$APP_DIR/.admin_pass_hash")
    
# Start application
proot-distro login debian -- bash -c "
    cd $APP_DIR
    source /opt/venv/bin/activate
    export ADMIN_PASSWORD_HASH='$(cat .admin_pass_hash)'
    nohup python3 -m uvicorn backend.main:app --host 127.0.0.1 --port 8000 > logs/app.log 2>&1 &
    echo \$! > app.pid
"
    
    # Also start cloudflared if token is available
    if [ -f "$APP_DIR/.env" ]; then
        source "$APP_DIR/.env"
        if [ ! -z "$TUNNEL_TOKEN" ]; then
            echo "Starting Cloudflare Tunnel..."
            nohup "$APP_DIR/bin/cloudflared" tunnel --original-client-ip --token "$TUNNEL_TOKEN" run > "$APP_DIR/logs/tunnel.log" 2>&1 &
            echo $! > "$APP_DIR/tunnel.pid"
        fi
    fi
    echo "App and Tunnel started."
}

backup() {
    echo "Creating backup..."
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="backup_$TIMESTAMP.tar.gz"
    # Create archive of db and public images
    tar -czf "$BACKUP_FILE" gallery.db uploads/public
    # Encrypt
    read -s -p "Enter Backup Encryption Password: " BACKUP_PASS
    echo ""
    gpg --symmetric --batch --passphrase "$BACKUP_PASS" "$BACKUP_FILE"
    rm "$BACKUP_FILE"
    echo "Backup created: $BACKUP_FILE.gpg"
}

restore() {
    FILE=$1
    if [ -z "$FILE" ]; then
        echo "Usage: $0 restore <file.gpg>"
        return
    fi
    read -s -p "Enter Backup Decryption Password: " BACKUP_PASS
    echo ""
    gpg --decrypt --batch --passphrase "$BACKUP_PASS" "$FILE" > restored.tar.gz
    tar -xzf restored.tar.gz
    rm restored.tar.gz
    echo "Restore complete."
}

status() {
    if [ -f "$PID_FILE" ]; then
        echo "App is running (PID: $(cat $PID_FILE))"
    else
        echo "App is not running."
    fi
}

case "$1" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) status ;;
    backup) backup ;;
    restore) restore "$2" ;;
    *) echo "Usage: $0 {start|stop|restart|status|backup|restore}" ;;
esac
