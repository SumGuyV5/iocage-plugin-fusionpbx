#!/bin/sh -x
interface=$(ifconfig -l | awk '{print $1}')
if [ .$interface = .'lo0' ]; then
	interface=$(ifconfig -l | awk '{print $2}')
	if [ .$interface = .'epair0b' ]; then
		interface=$(ifconfig -l | awk '{print $3}')
	fi
fi

#get the install script
cd /usr/src && git clone https://github.com/fusionpbx/fusionpbx-install.sh.git

#change the working directory
cd /usr/src/fusionpbx-install.sh/freebsd/

#replace /dev/random with openssl for password gen
find /usr/src/fusionpbx-install.sh/freebsd/ -type f -name '*.sh' -exec sed -i .bak -e 's/cat \/dev\/random/openssl rand -base64 20/g' {} \+

#change config file
sed -i' ' -e s:'system_branch=.*:system_branch=stable:g' resources/config.sh
sed -i' ' -e s:'database_version=.*:database_version=13:g' resources/config.sh
sed -i' ' -e s:"interface_name=.*:interface_name=${interface}:g" resources/config.sh

#fail2ban is now using py38
sed -i' ' -e s:'pkg install --yes py37-fail2ban:pkg install --yes py38-fail2ban:g' resources/fail2ban.sh


#lets the 'finish' script output to the PLUGIN_INFO
sed -i' ' -e '/echo " / s|$| >> /root/PLUGIN_INFO|' resources/finish.sh
sed -i '' -e '141s|echo "" >>|echo "" >|g' resources/finish.sh

./install.sh