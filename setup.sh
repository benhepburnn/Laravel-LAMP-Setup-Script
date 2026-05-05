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
DOMAIN="${DOMAIN:-}"
INCLUDE_WWW="${INCLUDE_WWW:-prompt}"
REPO_URL="${REPO_URL:-}"
REPO_BRANCH="${REPO_BRANCH:-}"
QUEUE_WORKERS="${QUEUE_WORKERS:-3}"
SWAP_FILE="${SWAP_FILE:-/swapfile}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"
PHP_PACKAGES="${PHP_PACKAGES:-php php-fpm php-mysqli php-json php-devel php-bcmath php-mbstring php-xml php-gd php-intl php-zip php-process php-opcache}"

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
	"$@" >/dev/null
	success "$message"
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
	sudo systemctl enable --now "$service" >/dev/null
	success "$service is enabled"
}

append_line_once() {
	local file="$1"
	local line="$2"
	sudo touch "$file"
	if ! sudo grep -Fxq "$line" "$file"; then
		printf '%s\n' "$line" | sudo tee -a "$file" >/dev/null
	fi
}

write_root_file() {
	local file="$1"
	local content="$2"
	printf '%s\n' "$content" | sudo tee "$file" >/dev/null
}

prepare_system() {
	if confirm "Upgrade installed packages" "yes" "$RUN_DNF_UPGRADE"; then
		run_quiet "Upgrading packages" sudo dnf upgrade -y
	fi

	install_packages httpd git wget tar unzip
	enable_service httpd

	log "Adding $APP_USER to $WEB_GROUP group"
	sudo usermod -a -G "$WEB_GROUP" "$APP_USER"
	success "$APP_USER is a member of $WEB_GROUP after next login"

	git config --global core.fileMode false
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
		run_quiet "Creating ${SWAP_SIZE_MB}MB swap file" sudo fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE"
		sudo chmod 600 "$SWAP_FILE"
		sudo mkswap "$SWAP_FILE" >/dev/null
	fi

	sudo swapon "$SWAP_FILE"
	append_line_once /etc/fstab "$SWAP_FILE swap swap defaults 0 0"
	success "Swap configured"
}

install_php() {
	# shellcheck disable=SC2206
	local packages=($PHP_PACKAGES)
	install_packages "${packages[@]}"
	enable_service php-fpm
}

install_mariadb() {
	if ! confirm "Install MariaDB locally" "yes" "$INSTALL_MARIADB"; then
		return
	fi

	install_packages mariadb105-server
	enable_service mariadb

	if confirm "Run mysql_secure_installation now" "yes" "$SECURE_MARIADB"; then
		log "Launching mysql_secure_installation"
		sudo mysql_secure_installation
	fi
}

setup_permissions() {
	[[ "$(normalize_bool "$SET_PERMISSIONS")" == "yes" ]] || return 0

	log "Setting ownership and permissions for /var/www"
	sudo mkdir -p "$APP_DIR"
	sudo chown -R "$APP_USER:$WEB_GROUP" /var/www
	sudo chmod 2775 /var/www
	sudo find /var/www -type d -exec chmod 2775 {} \;
	sudo find /var/www -type f -exec chmod 0664 {} \;
	success "Base web permissions set"
}

setup_ssh_key() {
	if [[ -r "$HOME/.ssh/id_ed25519.pub" || -r "$HOME/.ssh/id_rsa.pub" ]]; then
		return
	fi

	if ! confirm "Generate an SSH deploy key" "yes" "$GENERATE_SSH_KEY"; then
		return
	fi

	mkdir -p "$HOME/.ssh"
	chmod 700 "$HOME/.ssh"
	ssh-keygen -q -t ed25519 -N "" -C "$APP_USER@$(hostname)" -f "$HOME/.ssh/id_ed25519"
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

	[[ -n "$REPO_URL" ]] || die "A repository URL is required when repository setup is enabled."

	if [[ -d "$APP_DIR/.git" ]]; then
		warn "$APP_DIR already contains a Git repository; skipping clone"
		return
	fi

	if [[ -n "$(find "$APP_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
		die "$APP_DIR is not empty. Set SETUP_REPOSITORY=no or empty the directory before cloning."
	fi

	log "Cloning repository"
	if [[ "$REPO_URL" == git\ clone* ]]; then
		# Allows pasting the familiar clone command while still forcing the target path.
		local clone_args
		clone_args="${REPO_URL#git clone }"
		# shellcheck disable=SC2086
		git clone $clone_args "$APP_DIR"
	elif [[ -n "$REPO_BRANCH" ]]; then
		git clone --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
	else
		git clone "$REPO_URL" "$APP_DIR"
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
		die "Composer installer checksum failed."
	fi

	sudo php "$installer" --quiet --install-dir="$(dirname "$COMPOSER_PATH")" --filename="$(basename "$COMPOSER_PATH")"
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

	sudo mkdir -p "$document_root"

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
	write_root_file "$VHOST_FILE" "$config"
	sudo apachectl configtest >/dev/null
	sudo systemctl restart httpd
	success "Apache virtual host configured"
}

setup_scheduler() {
	if ! confirm "Add Laravel scheduler cron entry" "yes" "$SETUP_SCHEDULER"; then
		return
	fi

	local entry="* * * * * $APP_USER cd $APP_DIR && php artisan schedule:run >> /dev/null 2>&1"
	append_line_once /etc/crontab "$entry"
	sudo systemctl restart crond
	success "Laravel scheduler configured"
}

open_database_shell() {
	if ! sudo systemctl is-active --quiet mariadb; then
		return
	fi

	if confirm "Open MariaDB shell to create the application database" "no" "$OPEN_DB_SHELL"; then
		mysql -u root -p
	fi
}

install_certbot() {
	if ! confirm "Install and run Certbot for HTTPS" "yes" "$INSTALL_CERTBOT"; then
		return
	fi

	[[ -n "$DOMAIN" ]] || prompt_value DOMAIN "Domain for certificate"
	[[ -n "$DOMAIN" ]] || die "DOMAIN is required for Certbot."
	resolve_include_www
	prompt_value CERTBOT_EMAIL "Email for Let's Encrypt notices (optional)" "$CERTBOT_EMAIL"

	install_packages python3 python3-devel augeas-devel gcc
	log "Installing Certbot in /opt/certbot"
	sudo python3 -m venv /opt/certbot/
	sudo /opt/certbot/bin/pip install --upgrade pip >/dev/null
	sudo /opt/certbot/bin/pip install certbot certbot-apache >/dev/null

	sudo ln -sf /opt/certbot/bin/certbot "$CERTBOT_BIN"

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

	sudo "$CERTBOT_BIN" "${certbot_args[@]}"
	append_line_once /etc/crontab "39 1,13 * * * root $CERTBOT_BIN renew --quiet"
	sudo systemctl restart crond
	success "Certbot configured"
}

final_laravel_permissions() {
	[[ "$(normalize_bool "$SET_PERMISSIONS")" == "yes" ]] || return 0
	[[ -d "$APP_DIR" ]] || return 0

	log "Setting Laravel app permissions"
	sudo chown -R "$APP_USER:$WEB_GROUP" "$APP_DIR"
	sudo find "$APP_DIR" -type f -exec chmod 664 {} \;
	sudo find "$APP_DIR" -type d -exec chmod 775 {} \;

	if [[ -d "$APP_DIR/storage" ]]; then
		sudo chgrp -R "$WEB_GROUP" "$APP_DIR/storage"
		sudo chmod -R ug+rwx "$APP_DIR/storage"
	fi

	if [[ -d "$APP_DIR/bootstrap/cache" ]]; then
		sudo chgrp -R "$WEB_GROUP" "$APP_DIR/bootstrap/cache"
		sudo chmod -R ug+rwx "$APP_DIR/bootstrap/cache"
	fi

	success "Laravel permissions set"
}

install_supervisor() {
	if ! confirm "Install Supervisor for Laravel queue workers" "no" "$INSTALL_SUPERVISOR"; then
		return
	fi

	install_packages supervisor
	enable_service supervisord

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
	write_root_file /etc/supervisord.d/laravel-queue-worker.ini "$config"
	sudo supervisorctl reread >/dev/null
	sudo supervisorctl update >/dev/null
	sudo supervisorctl restart laravel-queue-worker:* >/dev/null || sudo supervisorctl start laravel-queue-worker:* >/dev/null
	success "Supervisor queue workers configured"
}

print_summary() {
	printf '\n%s\n' "${GREEN}${BOLD}Laravel LAMP setup finished.${RESET}"
	printf '%s\n' "App directory: $APP_DIR"
	printf '%s\n' "Apache vhost:  $VHOST_FILE"
	printf '%s\n' "Next steps: edit $APP_DIR/.env, run composer install if needed, then run your deploy script."
}

main() {
	printf '%s\n' "${BOLD}Laravel LAMP setup for Amazon Linux 2023${RESET}"
	require_al2023
	prepare_system
	setup_swap
	install_php
	install_mariadb
	setup_permissions
	setup_repository
	install_composer
	configure_apache
	setup_scheduler
	open_database_shell
	install_certbot
	final_laravel_permissions
	install_supervisor
	print_summary
}

main "$@"
