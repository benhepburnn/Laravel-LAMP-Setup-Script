#!/usr/bin/env bash

set -Eeuo pipefail

if [[ -t 1 ]]; then
	RED=$'\033[0;31m'
	GREEN=$'\033[0;32m'
	YELLOW=$'\033[1;33m'
	BLUE=$'\033[0;34m'
	BOLD=$'\033[1m'
	RESET=$'\033[0m'
else
	RED=""
	GREEN=""
	YELLOW=""
	BLUE=""
	BOLD=""
	RESET=""
fi

APP_USER="${APP_USER:-ec2-user}"
WEB_GROUP="${WEB_GROUP:-apache}"
APP_DIR="${APP_DIR:-/var/www/html}"
PUBLIC_DIR="${PUBLIC_DIR:-public}"
VHOST_FILE="${VHOST_FILE:-/etc/httpd/conf.d/laravel.conf}"
COMPOSER_PATH="${COMPOSER_PATH:-/usr/local/bin/composer}"
CERTBOT_BIN="${CERTBOT_BIN:-/usr/local/bin/certbot}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
CERTBOT_PYTHON="${CERTBOT_PYTHON:-python3}"
CERTBOT_PYTHON_PACKAGES="${CERTBOT_PYTHON_PACKAGES:-python3 python3-devel}"
DOMAIN="${DOMAIN:-}"
INCLUDE_WWW="${INCLUDE_WWW:-prompt}"
REPO_URL="${REPO_URL:-}"
REPO_BRANCH="${REPO_BRANCH:-}"
QUEUE_WORKERS="${QUEUE_WORKERS:-3}"
SWAP_FILE="${SWAP_FILE:-/swapfile}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"
PHP_PACKAGES="${PHP_PACKAGES:-php php-fpm php-mysqli php-json php-devel php-bcmath php-mbstring php-xml php-gd php-intl php-zip php-process php-opcache}"
SCHEDULER_DRIVER="${SCHEDULER_DRIVER:-systemd}"

INTERACTIVE="${INTERACTIVE:-auto}"
RUN_DNF_UPGRADE="${RUN_DNF_UPGRADE:-prompt}"
SETUP_SWAP="${SETUP_SWAP:-prompt}"
INSTALL_MARIADB="${INSTALL_MARIADB:-prompt}"
SECURE_MARIADB="${SECURE_MARIADB:-prompt}"
INSTALL_CERTBOT="${INSTALL_CERTBOT:-prompt}"
INSTALL_SUPERVISOR="${INSTALL_SUPERVISOR:-prompt}"
SETUP_SCHEDULER="${SETUP_SCHEDULER:-prompt}"
SETUP_REPOSITORY="${SETUP_REPOSITORY:-prompt}"
SETUP_COMPOSER="${SETUP_COMPOSER:-yes}"
SETUP_APACHE="${SETUP_APACHE:-yes}"
SET_PERMISSIONS="${SET_PERMISSIONS:-yes}"
OPEN_DB_SHELL="${OPEN_DB_SHELL:-prompt}"
GENERATE_SSH_KEY="${GENERATE_SSH_KEY:-prompt}"

FAILED_STEPS=()

log() {
	printf '%s\n' "${BLUE}==>${RESET} ${BOLD}$*${RESET}"
}

success() {
	printf '%s\n' "${GREEN}✓${RESET} $*"
}

warn() {
	printf '%s\n' "${YELLOW}!${RESET} $*"
}

die() {
	printf '%s\n' "${RED}Error:${RESET} $*" >&2
	exit 1
}

is_interactive() {
	[[ "$INTERACTIVE" == "yes" ]] || { [[ "$INTERACTIVE" == "auto" ]] && [[ -t 0 ]]; }
}

normalize_bool() {
	case "${1,,}" in
		y|yes|true|1|on) printf 'yes' ;;
		n|no|false|0|off) printf 'no' ;;
		*) return 1 ;;
	esac
}

confirm() {
	local prompt="$1"
	local default="${2:-yes}"
	local value="${3:-prompt}"
	local normalized

	if [[ "$value" != "prompt" && -n "$value" ]]; then
		normalized="$(normalize_bool "$value")" || die "Invalid boolean value '$value' for: $prompt"
		[[ "$normalized" == "yes" ]]
		return
	fi

	if ! is_interactive; then
		[[ "$default" == "yes" ]]
		return
	fi

	local suffix="[Y/n]"
	[[ "$default" == "no" ]] && suffix="[y/N]"

	while true; do
		read -r -p "$(printf '%s%s%s? %s ' "$BOLD" "$prompt" "$RESET" "$suffix")" reply
		reply="${reply:-$default}"
		normalized="$(normalize_bool "$reply")" && { [[ "$normalized" == "yes" ]]; return; }
		warn "Please answer yes or no."
	done
}

resolve_include_www() {
	if [[ "$INCLUDE_WWW" != "prompt" && -n "$INCLUDE_WWW" ]]; then
		normalize_bool "$INCLUDE_WWW" >/dev/null || die "Invalid INCLUDE_WWW value '$INCLUDE_WWW'."
		return
	fi

	if [[ -z "$DOMAIN" ]]; then
		INCLUDE_WWW="no"
		return
	fi

	if confirm "Add www.$DOMAIN as a ServerAlias" "yes" "prompt"; then
		INCLUDE_WWW="yes"
	else
		INCLUDE_WWW="no"
	fi
}

prompt_value() {
	local variable_name="$1"
	local prompt="$2"
	local default="${3:-}"
	local current="${!variable_name:-}"

	if [[ -n "$current" ]]; then
		return
	fi

	if ! is_interactive; then
		printf -v "$variable_name" '%s' "$default"
		return
	fi

	if [[ -n "$default" ]]; then
		read -r -p "$(printf '%s [%s]: ' "$prompt" "$default")" reply
		printf -v "$variable_name" '%s' "${reply:-$default}"
	else
		read -r -p "$(printf '%s: ' "$prompt")" reply
		printf -v "$variable_name" '%s' "$reply"
	fi
}

run_quiet() {
	local message="$1"
	shift
	log "$message"
	"$@" >/dev/null || return
	success "$message"
}

run_step() {
	local label="$1"
	local critical="$2"
	local step_function="$3"
	local status

	set +e
	"$step_function"
	status=$?
	set -e

	if ((status == 0)); then
		return 0
	fi

	if [[ "$critical" == "yes" ]]; then
		die "$label failed."
	fi

	warn "$label failed; continuing with the remaining setup."
	FAILED_STEPS+=("$label")
	return 0
}

require_al2023() {
	[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
	# shellcheck disable=SC1091
	source /etc/os-release

	[[ "${ID:-}" == "amzn" && "${VERSION_ID:-}" == "2023" ]] || die "This installer is intended for Amazon Linux 2023. Detected ID=${ID:-unknown}, VERSION_ID=${VERSION_ID:-unknown}."
	command -v dnf >/dev/null || die "dnf is required."
	command -v sudo >/dev/null || die "sudo is required."
	sudo -n true 2>/dev/null || die "Passwordless sudo is required. On Amazon Linux 2023, run as ec2-user from the official EC2 image or fix sudoers so ec2-user can run sudo without a password."
}

install_packages() {
	local packages=("$@")
	((${#packages[@]} > 0)) || return 0
	run_quiet "Installing packages: ${packages[*]}" sudo dnf install -y "${packages[@]}"
}

enable_service() {
	local service="$1"
	log "Starting and enabling $service"
	sudo systemctl enable --now "$service" >/dev/null || return
	success "$service is enabled"
}

append_line_once() {
	local file="$1"
	local line="$2"
	sudo touch "$file" || return
	if ! sudo grep -Fxq "$line" "$file"; then
		printf '%s\n' "$line" | sudo tee -a "$file" >/dev/null || return
	fi
}

write_root_file() {
	local file="$1"
	local content="$2"
	printf '%s\n' "$content" | sudo tee "$file" >/dev/null || return
}

ensure_cron() {
	install_packages cronie || return
	enable_service crond || return
}

prepare_system() {
	if confirm "Upgrade installed packages" "yes" "$RUN_DNF_UPGRADE"; then
		run_quiet "Upgrading packages" sudo dnf upgrade -y || return
	fi

	install_packages httpd git wget tar unzip || return
	enable_service httpd || return

	log "Adding $APP_USER to $WEB_GROUP group"
	sudo usermod -a -G "$WEB_GROUP" "$APP_USER" || return
	success "$APP_USER is a member of $WEB_GROUP after next login"

	git config --global core.fileMode false || return
}

setup_swap() {
	if ! confirm "Create swap file" "yes" "$SETUP_SWAP"; then
		return
	fi

	if sudo swapon --show=NAME | grep -Fxq "$SWAP_FILE"; then
		success "Swap already enabled at $SWAP_FILE"
		return
	fi

	if [[ -e "$SWAP_FILE" ]]; then
		warn "$SWAP_FILE already exists; enabling it if possible"
	else
		run_quiet "Creating ${SWAP_SIZE_MB}MB swap file" sudo fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE" || return
		sudo chmod 600 "$SWAP_FILE" || return
		sudo mkswap "$SWAP_FILE" >/dev/null || return
	fi

	sudo swapon "$SWAP_FILE" || return
	append_line_once /etc/fstab "$SWAP_FILE swap swap defaults 0 0" || return
	success "Swap configured"
}

install_php() {
	# shellcheck disable=SC2206
	local packages=($PHP_PACKAGES)
	install_packages "${packages[@]}" || return
	enable_service php-fpm || return
}

install_mariadb() {
	if ! confirm "Install MariaDB locally" "yes" "$INSTALL_MARIADB"; then
		return
	fi

	install_packages mariadb105-server || return
	enable_service mariadb || return

	if confirm "Run mysql_secure_installation now" "yes" "$SECURE_MARIADB"; then
		log "Launching mysql_secure_installation"
		sudo mysql_secure_installation || return
	fi
}

setup_permissions() {
	[[ "$(normalize_bool "$SET_PERMISSIONS")" == "yes" ]] || return 0

	log "Setting ownership and permissions for /var/www"
	sudo mkdir -p "$APP_DIR" || return
	sudo chown -R "$APP_USER:$WEB_GROUP" /var/www || return
	sudo chmod 2775 /var/www || return
	sudo find /var/www -type d -exec chmod 2775 {} \; || return
	sudo find /var/www -type f -exec chmod 0664 {} \; || return
	success "Base web permissions set"
}

setup_ssh_key() {
	if [[ -r "$HOME/.ssh/id_ed25519.pub" || -r "$HOME/.ssh/id_rsa.pub" ]]; then
		return
	fi

	if ! confirm "Generate an SSH deploy key" "yes" "$GENERATE_SSH_KEY"; then
		return
	fi

	mkdir -p "$HOME/.ssh" || return
	chmod 700 "$HOME/.ssh" || return
	ssh-keygen -q -t ed25519 -N "" -C "$APP_USER@$(hostname)" -f "$HOME/.ssh/id_ed25519" || return
}

show_public_keys() {
	local key
	for key in "$HOME"/.ssh/*.pub; do
		[[ -r "$key" ]] || continue
		printf '\n%s\n' "${BOLD}SSH public key ($key):${RESET}"
		cat "$key"
	done
}

setup_repository() {
	if ! confirm "Clone a Laravel repository into $APP_DIR" "yes" "$SETUP_REPOSITORY"; then
		return
	fi

	setup_ssh_key
	show_public_keys
	prompt_value REPO_URL "Git repository URL or clone command"

	if [[ -z "$REPO_URL" ]]; then
		warn "A repository URL is required when repository setup is enabled."
		return 1
	fi

	if [[ -d "$APP_DIR/.git" ]]; then
		warn "$APP_DIR already contains a Git repository; skipping clone"
		return
	fi

	if [[ -n "$(find "$APP_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
		warn "$APP_DIR is not empty. Set SETUP_REPOSITORY=no or empty the directory before cloning."
		return 1
	fi

	log "Cloning repository"
	if [[ "$REPO_URL" == git\ clone* ]]; then
		# Allows pasting the familiar clone command while still forcing the target path.
		local clone_args
		clone_args="${REPO_URL#git clone }"
		# shellcheck disable=SC2086
		git clone $clone_args "$APP_DIR" || return
	elif [[ -n "$REPO_BRANCH" ]]; then
		git clone --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR" || return
	else
		git clone "$REPO_URL" "$APP_DIR" || return
	fi
	success "Repository cloned"
}

install_composer() {
	[[ "$(normalize_bool "$SETUP_COMPOSER")" == "yes" ]] || return 0

	if command -v composer >/dev/null; then
		success "Composer already installed at $(command -v composer)"
		return
	fi

	log "Installing Composer"
	local installer expected actual
	installer="$(mktemp)"
	expected="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
	php -r "copy('https://getcomposer.org/installer', '$installer');"
	actual="$(php -r "echo hash_file('sha384', '$installer');")"

	if [[ "$expected" != "$actual" ]]; then
		rm -f "$installer"
		warn "Composer installer checksum failed."
		return 1
	fi

	sudo php "$installer" --quiet --install-dir="$(dirname "$COMPOSER_PATH")" --filename="$(basename "$COMPOSER_PATH")" || return
	rm -f "$installer"
	success "Composer installed at $COMPOSER_PATH"
}

configure_apache() {
	[[ "$(normalize_bool "$SETUP_APACHE")" == "yes" ]] || return 0

	prompt_value DOMAIN "Domain for Apache ServerName" "$DOMAIN"
	resolve_include_www

	local document_root="$APP_DIR/$PUBLIC_DIR"
	local alias_line=""
	if [[ -n "$DOMAIN" && "$(normalize_bool "$INCLUDE_WWW")" == "yes" ]]; then
		alias_line="    ServerAlias www.$DOMAIN"
	fi

	sudo mkdir -p "$document_root" || return

	local server_name="${DOMAIN:-localhost}"
	local config
	config="<VirtualHost *:80>
    ServerName $server_name
$alias_line
    DocumentRoot \"$document_root\"

    <Directory \"$document_root\">
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog /var/log/httpd/laravel-error.log
    CustomLog /var/log/httpd/laravel-access.log combined
</VirtualHost>"

	log "Writing Apache virtual host to $VHOST_FILE"
	write_root_file "$VHOST_FILE" "$config" || return
	sudo apachectl configtest >/dev/null || return
	sudo systemctl restart httpd || return
	success "Apache virtual host configured"
}

setup_scheduler() {
	if ! confirm "Add Laravel scheduler" "yes" "$SETUP_SCHEDULER"; then
		return
	fi

	case "$SCHEDULER_DRIVER" in
		systemd)
			setup_scheduler_systemd
			;;
		cron)
			setup_scheduler_cron
			;;
		*)
			warn "Invalid SCHEDULER_DRIVER '$SCHEDULER_DRIVER'. Use 'systemd' or 'cron'."
			return 1
			;;
	esac
}

setup_scheduler_systemd() {
	local service_file="/etc/systemd/system/laravel-scheduler.service"
	local timer_file="/etc/systemd/system/laravel-scheduler.timer"
	local service_config
	local timer_config

	service_config="[Unit]
Description=Run Laravel scheduler

[Service]
Type=oneshot
User=$APP_USER
Group=$WEB_GROUP
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/php artisan schedule:run"

	timer_config="[Unit]
Description=Run Laravel scheduler every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Unit=laravel-scheduler.service

[Install]
WantedBy=timers.target"

	log "Writing Laravel scheduler systemd service and timer"
	write_root_file "$service_file" "$service_config" || return
	write_root_file "$timer_file" "$timer_config" || return
	sudo systemctl daemon-reload || return
	sudo systemctl enable --now laravel-scheduler.timer >/dev/null || return
	success "Laravel scheduler systemd timer configured"
}

setup_scheduler_cron() {
	ensure_cron || return

	local entry="* * * * * $APP_USER cd $APP_DIR && php artisan schedule:run >> /dev/null 2>&1"
	append_line_once /etc/crontab "$entry" || return
	sudo systemctl restart crond || return
	success "Laravel scheduler cron entry configured"
}

open_database_shell() {
	if ! sudo systemctl is-active --quiet mariadb; then
		return
	fi

	if confirm "Open MariaDB shell to create the application database" "no" "$OPEN_DB_SHELL"; then
		mysql -u root -p || return
	fi
}

install_certbot() {
	if ! confirm "Install and run Certbot for HTTPS" "yes" "$INSTALL_CERTBOT"; then
		return
	fi

	[[ -n "$DOMAIN" ]] || prompt_value DOMAIN "Domain for certificate"
	if [[ -z "$DOMAIN" ]]; then
		warn "DOMAIN is required for Certbot."
		return 1
	fi
	resolve_include_www
	prompt_value CERTBOT_EMAIL "Email for Let's Encrypt notices (optional)" "$CERTBOT_EMAIL"

	# shellcheck disable=SC2206
	local python_packages=($CERTBOT_PYTHON_PACKAGES)
	install_packages mod_ssl augeas-devel gcc "${python_packages[@]}" || return
	sudo systemctl restart httpd || return

	if ! sudo apachectl -M 2>/dev/null | grep -q 'ssl_module'; then
		warn "Apache ssl_module is not loaded. Certbot's Apache installer cannot continue."
		return 1
	fi

	command -v "$CERTBOT_PYTHON" >/dev/null || {
		warn "CERTBOT_PYTHON '$CERTBOT_PYTHON' was not found."
		return 1
	}

	log "Installing Certbot in /opt/certbot"
	sudo "$CERTBOT_PYTHON" -m venv /opt/certbot/ || return
	sudo /opt/certbot/bin/pip install --upgrade pip >/dev/null || return
	sudo /opt/certbot/bin/pip install certbot certbot-apache >/dev/null || return

	sudo ln -sf /opt/certbot/bin/certbot "$CERTBOT_BIN" || return

	local certbot_args=(--apache -d "$DOMAIN")
	if [[ "$(normalize_bool "${INCLUDE_WWW:-no}")" == "yes" ]]; then
		certbot_args+=(-d "www.$DOMAIN")
	fi

	if [[ -n "$CERTBOT_EMAIL" ]]; then
		certbot_args+=(--email "$CERTBOT_EMAIL" --agree-tos)
	else
		certbot_args+=(--register-unsafely-without-email --agree-tos)
	fi

	if ! is_interactive; then
		certbot_args+=(--non-interactive)
	fi

	sudo "$CERTBOT_BIN" "${certbot_args[@]}" || return
	setup_certbot_renewal || return
	success "Certbot configured"
}

setup_certbot_renewal() {
	local service_file="/etc/systemd/system/certbot-renew.service"
	local timer_file="/etc/systemd/system/certbot-renew.timer"
	local service_config
	local timer_config

	service_config="[Unit]
Description=Renew Let's Encrypt certificates

[Service]
Type=oneshot
ExecStart=$CERTBOT_BIN renew --quiet"

	timer_config="[Unit]
Description=Renew Let's Encrypt certificates twice daily

[Timer]
OnCalendar=*-*-* 01,13:39:00
RandomizedDelaySec=1h
Persistent=true
Unit=certbot-renew.service

[Install]
WantedBy=timers.target"

	log "Writing Certbot renewal systemd timer"
	write_root_file "$service_file" "$service_config" || return
	write_root_file "$timer_file" "$timer_config" || return
	sudo systemctl daemon-reload || return
	sudo systemctl enable --now certbot-renew.timer >/dev/null || return
}

final_laravel_permissions() {
	[[ "$(normalize_bool "$SET_PERMISSIONS")" == "yes" ]] || return 0
	[[ -d "$APP_DIR" ]] || return 0

	log "Setting Laravel app permissions"
	sudo chown -R "$APP_USER:$WEB_GROUP" "$APP_DIR" || return
	sudo find "$APP_DIR" -type f -exec chmod 664 {} \; || return
	sudo find "$APP_DIR" -type d -exec chmod 775 {} \; || return

	if [[ -d "$APP_DIR/storage" ]]; then
		sudo chgrp -R "$WEB_GROUP" "$APP_DIR/storage" || return
		sudo chmod -R ug+rwx "$APP_DIR/storage" || return
	fi

	if [[ -d "$APP_DIR/bootstrap/cache" ]]; then
		sudo chgrp -R "$WEB_GROUP" "$APP_DIR/bootstrap/cache" || return
		sudo chmod -R ug+rwx "$APP_DIR/bootstrap/cache" || return
	fi

	success "Laravel permissions set"
}

install_supervisor() {
	if ! confirm "Install Supervisor for Laravel queue workers" "no" "$INSTALL_SUPERVISOR"; then
		return
	fi

	install_packages supervisor || return
	enable_service supervisord || return

	local config
	config="[program:laravel-queue-worker]
process_name=%(program_name)s_%(process_num)02d
command=php $APP_DIR/artisan queue:work --sleep=3 --tries=3 --max-time=3600
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=$APP_USER
numprocs=$QUEUE_WORKERS
redirect_stderr=true
stdout_logfile=$APP_DIR/storage/logs/queue-worker.log
stopwaitsecs=3600"

	log "Writing Supervisor queue worker config"
	write_root_file /etc/supervisord.d/laravel-queue-worker.ini "$config" || return
	sudo supervisorctl reread >/dev/null || return
	sudo supervisorctl update >/dev/null || return
	sudo supervisorctl restart laravel-queue-worker:* >/dev/null || sudo supervisorctl start laravel-queue-worker:* >/dev/null || return
	success "Supervisor queue workers configured"
}

print_summary() {
	printf '\n%s\n' "${GREEN}${BOLD}Laravel LAMP setup finished.${RESET}"
	printf '%s\n' "App directory: $APP_DIR"
	printf '%s\n' "Apache vhost:  $VHOST_FILE"
	if ((${#FAILED_STEPS[@]} > 0)); then
		printf '\n%s\n' "${YELLOW}${BOLD}Completed with skipped or failed optional steps:${RESET}"
		printf ' - %s\n' "${FAILED_STEPS[@]}"
	fi
	printf '%s\n' "Next steps: edit $APP_DIR/.env, run composer install if needed, then run your deploy script."
}

main() {
	printf '%s\n' "${BOLD}Laravel LAMP setup for Amazon Linux 2023${RESET}"
	require_al2023
	run_step "Base system setup" "yes" prepare_system
	run_step "Swap setup" "no" setup_swap
	run_step "PHP setup" "yes" install_php
	run_step "MariaDB setup" "no" install_mariadb
	run_step "Base permissions setup" "no" setup_permissions
	run_step "Repository setup" "no" setup_repository
	run_step "Composer setup" "no" install_composer
	run_step "Apache virtual host setup" "no" configure_apache
	run_step "Laravel scheduler setup" "no" setup_scheduler
	run_step "Database shell" "no" open_database_shell
	run_step "Certbot setup" "no" install_certbot
	run_step "Laravel permissions setup" "no" final_laravel_permissions
	run_step "Supervisor setup" "no" install_supervisor
	print_summary
}

main "$@"
