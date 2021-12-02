#!/bin/sh -x

mkdir -p /var/cache/fusionpbx/
mkdir -p /var/www/letsencrypt/
mkdir -p /usr/local/etc/nginx/conf.d/
mkdir -p /usr/local/etc/nginx/sites-enabled/
mkdir -p /usr/local/etc/freeswitch/

#get the primary interface name
interface_name=$(ifconfig -l | awk '{print $1}')
if [ .$interface_name = .'lo0' ]; then
  interface_name=$(ifconfig -l | awk '{print $2}')
fi
if [ .$interface_name = .'pflog0' ]; then
  interface_name=$(ifconfig -l | awk '{print $3}')
fi

#get the ip address
local_ip_v4=$(ifconfig $interface_name | grep 'inet ' | awk '{print $2}')

#set the IP= address
common_name=$local_ip_v4

###########################
#  PF - Packet Filter
###########################
#send a message
echo "Configuring PF"

#enable the service
sysrc pf_enable="YES"
sysrc pf_rules="/etc/pf.conf"
#sysrc pf_flags=""
sysrc pflog_enable="YES"
sysrc pflog_logfile="/var/log/pflog"
#sysrc pflog_flags=""

###########################
#  FusionPBX
###########################
#send a message
echo "Installing FusionPBX"

#set the version
system_version=4.4
echo "Using version $system_version"
branch="-b $system_version"

#add the cache directory
chown -R www:www /var/cache/fusionpbx

#get the source code
fetch https://github.com/fusionpbx/fusionpbx/archive/4.4.tar.gz
tar -xf 4.4.tar.gz -C /usr/local/www
mv /usr/local/www/fusionpbx-4.4/ /usr/local/www/fusionpbx
#git clone $branch https://github.com/fusionpbx/fusionpbx.git /usr/local/www/fusionpbx
chown -R www:www /usr/local/www/fusionpbx

#php
#enable php fpm
sysrc php_fpm_enable="YES"

#set the default version of postgres
echo "DEFAULT_VERSIONS+=pgsql=11" >> /etc/make.conf
echo "DEFAULT_VERSIONS+=ssl=openssl" >> /etc/make.conf

#send a message
echo "Configuring PHP"

#update config if source is being used
cp /usr/local/etc/php.ini-production /usr/local/etc/php.ini
sed -i' ' -e s:'post_max_size = .*:post_max_size = 80M:g' /usr/local/etc/php.ini
sed -i' ' -e s:'upload_max_filesize = .*:upload_max_filesize = 80M:g' /usr/local/etc/php.ini
sed -i' ' -e s:'; max_input_vars = .*:max_input_vars = 8000:g' /usr/local/etc/php.ini

#restart php-fpm
service php-fpm restart

###########################
#  nginx
###########################
#send a message
echo "Installing the web server"

#enable nginx
sysrc nginx_enable="YES"

#enable fusionpbx nginx config
ln -s /usr/local/etc/nginx/sites-available/fusionpbx /usr/local/etc/nginx/sites-enabled/fusionpbx

#self signed certificate
/usr/bin/openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/C=US/ST=Online/L=SelfSigned/O=FusionPBX/CN=$common_name" \
    -keyout /usr/local/etc/nginx/server.key -out /usr/local/etc/nginx/server.crt

#restart php fpm and nginx
service php-fpm restart
service nginx restart


###########################
#  Fail2ban
###########################

#send a message
echo "Installing Fail2ban"

#enable fail2ban service
sysrc fail2ban_enable="YES"

#restart fail2ban
service fail2ban start

###########################
#  FreeSwitch
###########################

#install the package
#send a message
echo "Installing the FreeSWITCH package"

#enable the services
sysrc memcached_enable="YES"
sysrc freeswitch_enable="YES"
sysrc freeswitch_flags="-nonat"
sysrc freeswitch_user="www"
sysrc freeswitch_group="www"

#start the service
service memcached start

#copy the default conf directory
cp -R /usr/local/www/fusionpbx/resources/templates/conf/* /usr/local/etc/freeswitch

#copy the scripts
cp -R /usr/local/www/fusionpbx/resources/install/scripts /usr/local/share/freeswitch
chown -R www:www /usr/local/share/freeswitch

#default permissions
chown -R www:www /usr/local/etc/freeswitch
chown -R www:www /var/lib/freeswitch
chown -R www:www /usr/local/share/freeswitch
chown -R www:www /var/log/freeswitch
chown -R www:www /var/run/freeswitch

#restart the service
service freeswitch restart

#waiting to start
echo "Allow time for FreeSWITCH to start";
for i in `seq 1 3`; do
	echo $i
	sleep 1
done


###########################
#  PostgreSQL
###########################
#send a message

cwd=$(pwd)
cd /tmp

echo "Install PostgreSQL"

#generate a random password
password=$(openssl rand -base64 20 | md5 | head -c20)

#install message
echo "Install PostgreSQL and create the database and users\n"

#enable postgres
sysrc postgresql_enable="YES"

#initialize the database
/usr/local/etc/rc.d/postgresql initdb

#start postgresql
su -m postgres -c '/usr/local/bin/pg_ctl -D /var/db/postgres/data11 -l logfile start'

#restart the service
service postgresql start

su -m postgres -c psql <<EOF
CREATE DATABASE fusionpbx;
CREATE DATABASE freeswitch;
CREATE ROLE fusionpbx WITH SUPERUSER LOGIN PASSWORD '$password';
CREATE ROLE freeswitch WITH SUPERUSER LOGIN PASSWORD '$password';
GRANT ALL PRIVILEGES ON DATABASE fusionpbx to fusionpbx;
GRANT ALL PRIVILEGES ON DATABASE freeswitch to fusionpbx;
GRANT ALL PRIVILEGES ON DATABASE freeswitch to freeswitch;
\q
EOF

cd $cwd

###########################
#  Restart services
###########################
#restart services
service php-fpm restart
service nginx restart
service fail2ban restart

###########################
#  finish
###########################

cwd=$(pwd)

#database details
database
database_username=fusionpbx
database_password=$(openssl rand -base64 20 | md5 | head -c20)

#allow the script to use the new password
export PGPASSWORD=$database_password

#update the database password
su -m postgres -c psql <<EOF
ALTER USER fusionpbx WITH PASSWORD '$database_password';
ALTER USER freeswitch WITH PASSWORD '$database_password';
\q
EOF

#add the config.php
chown -R www:www /etc/fusionpbx
sed -i' ' -e s:'{database_username}:fusionpbx:' /etc/fusionpbx/config.php
sed -i' ' -e s:"{database_password}:$database_password:" /etc/fusionpbx/config.php

#add the database schema
cd /usr/local/www/fusionpbx && /usr/local/bin/php /usr/local/www/fusionpbx/core/upgrade/upgrade_schema.php > /dev/null 2>&1

#get the ip address
domain_name=$(ifconfig $interface_name | grep 'inet ' | awk '{print $2}')

#get the domain uuid
domain_uuid=$(uuidgen);

#add the domain name
psql --username=$database_username -c "insert into v_domains (domain_uuid, domain_name, domain_enabled) values('$domain_uuid', '$domain_name', 'true');"

#app defaults
cd /usr/local/www/fusionpbx && /usr/local/bin/php /usr/local/www/fusionpbx/core/upgrade/upgrade_domains.php

#add the user
user_uuid=$(/usr/local/bin/php /usr/local/www/fusionpbx/resources/uuid.php);
user_salt=$(/usr/local/bin/php /usr/local/www/fusionpbx/resources/uuid.php);
user_name='admin'

user_password=$(openssl rand -base64 20 | md5 | head -c20)

password_hash=$(php -r "echo md5('$user_salt$user_password');");
psql --username=$database_username -t -c "insert into v_users (user_uuid, domain_uuid, username, password, salt, user_enabled) values('$user_uuid', '$domain_uuid', '$user_name', '$password_hash', '$user_salt', 'true');"

#get the superadmin group_uuid
group_uuid=$(psql --username=$database_username -t -c "select group_uuid from v_groups where group_name = 'superadmin';");
group_uuid=$(echo $group_uuid | sed 's/^[[:blank:]]*//;s/[[:blank:]]*$//')

#add the user to the group
user_group_uuid=$(/usr/local/bin/php /usr/local/www/fusionpbx/resources/uuid.php);
group_name=superadmin

psql --username=$database_username -c "insert into v_group_users (group_user_uuid, domain_uuid, group_name, group_uuid, user_uuid) values('$user_group_uuid', '$domain_uuid', '$group_name', '$group_uuid', '$user_uuid');"

#add the local_ip_v4 address
psql --username=$database_username -t -c "insert into v_vars (var_uuid, var_name, var_value, var_category, var_order, var_enabled) values ('4507f7a9-2cbb-40a6-8799-f8f168082585', 'local_ip_v4', '$local_ip_v4', 'Defaults', '0', 'true');";

#app defaults
cd /usr/local/www/fusionpbx && php /usr/local/www/fusionpbx/core/upgrade/upgrade_domains.php

#reset the current working directory
cd $cwd

#update xml_cdr url, user and password
xml_cdr_username=$(openssl rand -base64 20 | md5 | head -c20)
xml_cdr_password=$(openssl rand -base64 20 | md5 | head -c20)

#set the conf directory
conf_dir="/usr/local/etc/freeswitch";

#update the xml_cdr.conf.xml file
sed -i' ' -e s:"{v_http_protocol}:http:" $conf_dir/autoload_configs/xml_cdr.conf.xml
sed -i' ' -e s:"{domain_name}:127.0.0.1:" $conf_dir/autoload_configs/xml_cdr.conf.xml
sed -i' ' -e s:"{v_project_path}::" $conf_dir/autoload_configs/xml_cdr.conf.xml
sed -i' ' -e s:"{v_user}:$xml_cdr_username:" $conf_dir/autoload_configs/xml_cdr.conf.xml
sed -i' ' -e s:"{v_pass}:$xml_cdr_password:" $conf_dir/autoload_configs/xml_cdr.conf.xml

# service freeswitch restart

#welcome message
echo "Installation has completed."
echo -e "FusionPBX now installed." > /root/PLUGIN_INFO
echo -e "   Use a web browser to login." >> /root/PLUGIN_INFO
echo -e "      domain name: http://$domain_name" >> /root/PLUGIN_INFO
echo -e "      username: $user_name" >> /root/PLUGIN_INFO
echo -e "      password: $user_password" >> /root/PLUGIN_INFO
echo -e "   The domain name in the browser is used by default as part of the authentication." >> /root/PLUGIN_INFO
echo -e "   If you need to login to a different domain then use username@domain." >> /root/PLUGIN_INFO
echo -e "      username: $user_name@$domain_name" >> /root/PLUGIN_INFO
echo -e "   Official FusionPBX Training" >> /root/PLUGIN_INFO
echo -e "      Fastest way to learn FusionPBX. For more information https://www.fusionpbx.com." >> /root/PLUGIN_INFO
echo -e "      Available online and in person. Includes documentation and recording." >> /root/PLUGIN_INFO
