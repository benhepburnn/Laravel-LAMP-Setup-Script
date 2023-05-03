#!/bin/sh

if [[ -z "${SETUP_STARTED}" ]]; then
	echo "Update packages"
	sudo yum update -y >> /dev/null

	echo "Install Apache"
	sudo yum install -y httpd >> /dev/null

	echo "Start and enable Apache service"
	sudo systemctl start httpd.service
	sudo systemctl enable httpd.service

	echo "Add user to apache group"
	sudo usermod -a -G apache ec2-user

	echo "Install git"
	sudo yum install -y git >> /dev/null
	
	echo "Disable Git File Permissions"
	git config --global core.fileMode false

	echo "Set up swap"
	sudo dd if=/dev/zero of=/swapfile bs=128M count=16
	sudo chmod 600 /swapfile
	sudo mkswap /swapfile
	sudo swapon /swapfile
	sudo swapon -s
	echo "/swapfile swap swap defaults 0 0" | sudo tee -a /etc/fstab
	free -m

	echo "export SETUP_STARTED=true" | tee -a ~/.bashrc

	# Exit
	echo "Exit and reconnect now"

	exit
fi

read -p "Install MariaDB? (y/n): " -n 1 -r
echo # new line
if [[ $REPLY =~ ^[Yy]$ ]]
then
	echo "Install MariaDB"
	sudo amazon-linux-extras install -y mariadb10.5 >> /dev/null

	echo "Start and enable service"
	sudo systemctl start mariadb
	sudo systemctl enable mariadb.service

	cat << EOF | sudo tee -a ~/restart_mariadb.sh
#!/bin/bash

# Check if MariaDB is running
sudo systemctl status mariadb > /dev/null 2>&1

# Restart the MariaDB service if it's not running.
if [ $? != 0 ]; then
    sudo systemctl restart mariadb
fi
EOF

	echo "Adding MariaDB watchdog to cron"
	echo "* * * * * /home/user/scripts/restart_mariadb.sh > /dev/null 2>&1" | sudo tee -a /etc/crontab

	echo "Secure DB"
	sudo mysql_secure_installation
fi

echo "Show user's groups"
groups

echo "Give user ownership of site root"
sudo chown -R ec2-user:apache /var/www

echo "Add group perms"
sudo chmod 2775 /var/www && find /var/www -type d -exec sudo chmod 2775 {} \;
find /var/www -type f -exec sudo chmod 0664 {} \;

echo "Install PHP"
sudo amazon-linux-extras install -y php8.0 >> /dev/null

echo "Install modules"
sudo yum install -y php-bcmath php-mbstring php-xml php-gd >> /dev/null

echo "Git:"
echo "Create SSH key"
ssh-keygen

echo "SSH public key:"
echo # new line
cat ~/.ssh/id_rsa.pub
echo # new line
echo "Add this key to the Git repo under settings > access keys"

read -p "Paste the ssh Git repo clone command: " -r
echo # New line

echo "Cloning..."
cd /var/www/html
$REPLY .

echo "Install composer"
cd ~
EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]
then
    >&2 echo 'ERROR: Invalid installer checksum'
    rm composer-setup.php
    exit 1
fi

php composer-setup.php --quiet
rm composer-setup.php
mv composer.phar /var/www/html

echo "Update Apache config"
sudo sed -i "s|\("^DocumentRoot" * *\).*|DocumentRoot /var/www/html/public|" /etc/httpd/conf/httpd.conf

read -p "Enter the domain to use: " -r DOMAIN
echo # New line
read -p "Include www.? (y/n): " -n 1 -r WWW
echo # new line

 [[ $WWW =~ ^[Yy]$ ]] && ALIAS="ServerAlias www.$DOMAIN" || ALIAS=""

echo 'Include /etc/httpd/sites-enabled/*.conf' | sudo tee -a /etc/httpd/conf/httpd.conf
sudo mkdir -p /etc/httpd/sites-{enabled,available}
sudo touch /etc/httpd/sites-available/site.conf

cat << EOF | sudo tee -a /etc/httpd/sites-available/site.conf
<VirtualHost *:80>
    DocumentRoot "/var/www/html/public"
    ServerName $DOMAIN
	$ALIAS

    <Directory "/var/www/html/public">
        Options Indexes FollowSymLinks
        AllowOverride All
    </Directory>
</VirtualHost>
EOF

sudo ln -s /etc/httpd/sites-available/site.conf /etc/httpd/sites-enabled/

echo "Apache config updated"

echo "Adding Laravel schedule to cron"
echo "* * * * * ec2-user cd /var/www/html && php artisan schedule:run >> /dev/null 2>&1" | sudo tee -a /etc/crontab

echo "Restart Apache and PHP"
sudo systemctl restart httpd.service
sudo systemctl restart php-fpm

echo "Create database now"
mysql -u root -p

echo "Installing Certbot"
sudo wget -r --no-parent -A 'epel-release-*.rpm' https://dl.fedoraproject.org/pub/epel/7/x86_64/Packages/e/
sudo rpm -Uvh dl.fedoraproject.org/pub/epel/7/x86_64/Packages/e/epel-release-*.rpm
sudo yum-config-manager --enable epel*
sudo amazon-linux-extras install epel -y
sudo yum install -y certbot python2-certbot-apache

sudo rm -r dl.fedoraproject.org
sudo certbot

echo "Adding certbot renew to cron"
echo "39      1,13    *       *       *       root    certbot renew --no-self-upgrade" | sudo tee -a /etc/crontab

echo "Restarting cron"
sudo systemctl restart crond

echo "Setting perms"
cd /var/www/html
sudo chown -R ec2-user:apache .
sudo find . -type f -exec chmod 664 {} \;   
sudo find . -type d -exec chmod 775 {} \;
sudo chgrp -R apache storage bootstrap/cache
sudo chmod -R ug+rwx storage bootstrap/cache
echo "Permissions set"

read -p "Install Supervisor? (y/n): " -n 1 -r
echo # new line
if [[ $REPLY =~ ^[Yy]$ ]]
then
echo "Install supervisor"
sudo yum install -y supervisor

sudo systemctl start supervisord

sudo systemctl enable supervisord

echo "Generate laravel queue worker"
cat << EOF | sudo tee -a /etc/supervisord.d/laravel-queue-worker.ini
[program:laravel-queue-worker]
process_name=%(program_name)s_%(process_num)02d
command=php /var/www/html/artisan queue:work --sleep=3 --tries=3 --max-time=3600
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=ec2-user
numprocs=3
redirect_stderr=true
stdout_logfile=/var/www/html/storage/logs/queue-worker.log
stopwaitsecs=3600
EOF

sudo supervisorctl reread

sudo supervisorctl update

sudo supervisorctl start all

echo "Supervisor installed"
fi

echo "Laravel LAMP Setup Finished!"

echo "Now edit .env and run ./deploy_laravel.sh"
