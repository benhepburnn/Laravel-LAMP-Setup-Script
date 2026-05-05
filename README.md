# Laravel LAMP Setup Script

Interactive and configurable installer for hosting a Laravel project on an AWS EC2 instance running Amazon Linux 2023.

It can install and configure Apache, PHP-FPM, optional MariaDB, optional Certbot HTTPS, optional Laravel scheduler, optional Supervisor queue workers, Composer, swap, and Laravel file permissions.

## Usage

Run interactively on a fresh Amazon Linux 2023 instance:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/benhepburnn/Laravel-LAMP-Setup-Script/master/setup.sh)
```

Or run from a local checkout:

```bash
bash setup.sh
```

The script uses friendly prompts by default. You can skip prompts by setting environment variables:

```bash
DOMAIN=example.com \
REPO_URL=git@github.com:example/app.git \
INSTALL_MARIADB=yes \
INSTALL_CERTBOT=yes \
INSTALL_SUPERVISOR=no \
bash setup.sh
```

For fully non-interactive runs:

```bash
INTERACTIVE=no \
DOMAIN=example.com \
INCLUDE_WWW=yes \
REPO_URL=git@github.com:example/app.git \
INSTALL_MARIADB=no \
INSTALL_CERTBOT=no \
INSTALL_SUPERVISOR=no \
SETUP_SCHEDULER=yes \
OPEN_DB_SHELL=no \
bash setup.sh
```

## Common Options

Boolean options accept `yes/no`, `true/false`, `1/0`, or `on/off`. Some options default to `prompt` in interactive mode.

| Variable | Default | Description |
| --- | --- | --- |
| `APP_USER` | `ec2-user` | Linux user that owns and deploys the app. |
| `WEB_GROUP` | `apache` | Web server group. |
| `APP_DIR` | `/var/www/html` | Laravel application directory. |
| `PUBLIC_DIR` | `public` | Laravel public document root inside `APP_DIR`. |
| `DOMAIN` | empty | Apache `ServerName` and Certbot domain. |
| `INCLUDE_WWW` | prompt | Adds `www.DOMAIN` as an alias and certificate name. |
| `REPO_URL` | empty | Git repository URL, or a pasted `git clone ...` command. |
| `REPO_BRANCH` | empty | Optional branch to clone. |
| `RUN_DNF_UPGRADE` | prompt | Run `dnf upgrade -y`. |
| `SETUP_SWAP` | prompt | Create and enable a swap file. |
| `SWAP_SIZE_MB` | `2048` | Swap file size in MB. |
| `INSTALL_MARIADB` | prompt | Install local MariaDB 10.5. |
| `SECURE_MARIADB` | prompt | Run `mysql_secure_installation`. |
| `INSTALL_CERTBOT` | prompt | Install Certbot with pip/venv and request a certificate. |
| `CERTBOT_EMAIL` | empty | Email used for Let's Encrypt notices. |
| `CERTBOT_PYTHON` | `python3` | Python executable used to create the Certbot virtualenv. |
| `CERTBOT_PYTHON_PACKAGES` | `python3 python3-devel` | Packages installed before creating the Certbot virtualenv. |
| `INSTALL_SUPERVISOR` | prompt | Install Supervisor queue worker config. |
| `QUEUE_WORKERS` | `3` | Number of Supervisor queue worker processes. |
| `SETUP_SCHEDULER` | prompt | Configure the Laravel scheduler. |
| `SCHEDULER_DRIVER` | `systemd` | Use `systemd` timer or `cron` for the Laravel scheduler. |
| `SETUP_REPOSITORY` | prompt | Clone the Laravel repo into `APP_DIR`. |
| `SETUP_COMPOSER` | `yes` | Install Composer globally if missing. |
| `SETUP_APACHE` | `yes` | Write `/etc/httpd/conf.d/laravel.conf`. |
| `SET_PERMISSIONS` | `yes` | Apply web/Laravel ownership and permissions. |
| `OPEN_DB_SHELL` | prompt | Open `mysql -u root -p` for manual database creation. |

## Notes

- The script checks that it is running on Amazon Linux 2023 before making changes.
- The script requires passwordless sudo. The official Amazon Linux 2023 EC2 `ec2-user` normally has this by default.
- Apache configuration is written to `/etc/httpd/conf.d/laravel.conf` and validated with `apachectl configtest`.
- Certbot installs `mod_ssl` first and verifies Apache has loaded `ssl_module` before requesting a certificate.
- The Laravel scheduler uses a systemd timer by default because `crond` is not always installed on Amazon Linux 2023.
- Re-running the script is supported for common operations. It avoids duplicate swap and cron entries, and rewrites systemd units safely.
- Optional setup steps report failure in the final summary and the installer continues with the remaining steps.
- Certbot requires the instance security group and DNS to allow HTTP/HTTPS validation for the configured domain.
