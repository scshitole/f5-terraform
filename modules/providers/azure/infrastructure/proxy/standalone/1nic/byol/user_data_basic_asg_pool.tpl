#!/bin/bash

# 1NIC BIG-IP ONBOARD SCRIPT

LOG_FILE=/var/log/startup-script.log
if [ ! -e $LOG_FILE ]
then
     touch $LOG_FILE
     exec &>>$LOG_FILE
else
    # if file exists, exit as only want to run once
    exit
fi

### ONBOARD INPUT PARAMS 

hostname='${hostname}'

# v13 uses mgmt for ifconfig & defaults to 8443 for GUI for Single Nic Deployments
if ifconfig mgmt; then managementInterface=mgmt; else managementInterface=eth0; fi
managementAddress=$(egrep -m 1 -A 1 $managementInterface /var/lib/dhclient/dhclient.leases | egrep -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
managementGuiPort=${management_gui_port}

adminUsername='${admin_username}'
adminPassword='${admin_password}'

dnsServer=${dns_server}
ntpServer=${ntp_server}
timezone=${timezone}

licenseKey1=${registration_key}


### DOWNLOAD ONBOARDING LIBS
# Could be pre-packaged or hosted internally

libs_dir="/config/cloud/azure/node_modules"
mkdir -p $libs_dir
curl -o /config/cloud/f5-cloud-libs.tar.gz --silent --fail --retry 60 -L https://raw.githubusercontent.com/F5Networks/f5-cloud-libs/v3.1.1/dist/f5-cloud-libs.tar.gz
curl -o /config/cloud/f5-cloud-libs-azure.tar.gz --silent --fail --retry 60 -L https://raw.githubusercontent.com/F5Networks/f5-cloud-libs-azure/v1.2.0/dist/f5-cloud-libs-azure.tar.gz
tar xvfz /config/cloud/f5-cloud-libs.tar.gz -C $libs_dir
tar xvfz /config/cloud/f5-cloud-libs-azure.tar.gz -C $libs_dir/f5-cloud-libs/node_modules


### BEGIN BASIC ONBOARDING 

# WAIT FOR MCPD (DATABASE) TO BE UP TO BEGIN F5 CONFIG

. $libs_dir/f5-cloud-libs/scripts/util.sh
wait_for_bigip

# PASSWORD
# Generate Random Password
#f5-rest-node $libs_dir/f5-cloud-libs/scripts/generatePassword --file /config/cloud/aws/.adminPassword"
#adminPassword=$(/bin/sed -e $'s:[!\\'\"%{};/|#\\x20\\\\\\\\]:\\\\\\\\&:g' < /config/cloud/aws/.adminPassword)      
# Use Password Provided as Input Param
tmsh create auth user $${adminUsername} password $${adminPassword} shell bash partition-access replace-all-with { all-partitions { role admin } }
tmsh save /sys config

# License / Provision
f5-rest-node $libs_dir/f5-cloud-libs/scripts/onboard.js \
-o  /var/log/onboard.log \
--no-reboot \
--port $${managementGuiPort} \
--ssl-port $${managementGuiPort} \
--host localhost \
--user $${adminUsername} \
--password $${adminPassword} \
--hostname $${hostname} \
--global-setting hostname:$${hostname} \
--dns $${dnsServer} \
--ntp $${ntpServer} \
--tz $${timezone} \
--module ltm:nominal \
--ping www.f5.com 30 15 \ 
--license $${licenseKey1} \



############ BEGIN CUSTOM CONFIG ############

# SOME HIGH LEVEL CONFIG PARAMS

region="${region}"

applicationName=${application}
virtualServiceDns=${vs_dns_name}
virtualServiceAddress=${vs_address}
virtualServiceMask=${vs_mask}
virtualServicePort=${vs_port}

applicationPort=${pool_member_port}
applicationPoolName=${pool_name}
applicationPoolTagKey=${pool_tag_key}
applicationPoolTagValue=${pool_tag_value}

subscriptionID="${azure_subscription_id}"
tenantId="${azure_tenant_id}"
resourceGroupName="${azure_resource_group}"
clientId="${azure_client_id}"
servicePrincipalSecret="${azure_sp_secret}"


# DOWNLOAD SOME FILES
curl --silent --fail --retry 20 -o /config/cloud/f5.http.v1.2.0.tmpl https://raw.githubusercontent.com/f5devcentral/f5-cloud-init-examples/master/files/iApp/f5.http.v1.2.0.tmpl
curl --silent --fail --retry 20 -o /config/cloud/appsvcs_integration_v2.1_001.tmpl https://raw.githubusercontent.com/f5devcentral/f5-cloud-init-examples/master/files/iApp/appsvcs_integration_v2.1_001.tmpl
curl --silent --fail --retry 20 -o /config/cloud/f5.service_discovery.tmpl https://raw.githubusercontent.com/f5devcentral/f5-cloud-init-examples/master/files/iApp/f5.service_discovery.tmpl
curl --silent --fail --retry 20 -o /config/cloud/f5.analytics.tmpl https://raw.githubusercontent.com/f5devcentral/f5-cloud-init-examples/master/files/iApp/f5.analytics.tmpl

# Load iApps
tmsh load sys application template /config/cloud/f5.http.v1.2.0.tmpl
tmsh load sys application template /config/cloud/appsvcs_integration_v2.1_001.tmpl
tmsh load sys application template /config/cloud/f5.service_discovery.tmpl
tmsh load sys application template /config/cloud/f5.analytics.tmpl


# CREATE SSL PROFILES
tmsh install sys crypto cert site.example.com from-local-file /config/ssl/ssl.crt/default.crt
tmsh install sys crypto key site.example.com from-local-file /config/ssl/ssl.key/default.key


# SERVICE DISCOVERY
# POOL = ASG
tmsh create ltm pool $${applicationPoolName} monitor http

tmsh create sys application service $${applicationName}_sd { template f5.service_discovery variables add { basic__advanced { value no } basic__display_help { value hide } cloud__azure_client_id { value $${clientId} } cloud__azure_resource_group { value $${resourceGroupName} } cloud__azure_sp_secret { encrypted yes value $${servicePrincipalSecret} } cloud__azure_subscription_id { value $${subscriptionID} } cloud__azure_tenant_id { value $${tenantId} } cloud__cloud_provider { value azure } pool__interval { value 60 } pool__member_conn_limit { value 0 } pool__member_port { value $${applicationPort} } pool__pool_to_use { value /Common/$${applicationPoolName} } pool__public_private { value private } pool__tag_key { value $${applicationPoolTagKey} } pool__tag_value { value $${applicationPoolTagValue} }  }}


# SERVICE INSERTION: CREATE VIRTUAL
tmsh create sys application service $${applicationName} { template f5.http.v1.2.0 tables add { pool__hosts { column-names { name } rows { { row { $${virtualServiceDns} } } } } pool__members { column-names { addr port connection_limit } rows {{ row { $${applicationName} $${applicationPort} 0 }}}}} variables add { pool__addr { value $${virtualServiceAddress} } pool__mask { value $${virtualServiceMask} } pool__port { value $${virtualServicePort} } pool__port_secure { value $${virtualServicePort} } net__vlan_mode { value all } ssl__cert { value /Common/site.example.com.crt } ssl__key { value /Common/site.example.com.key } ssl__mode { value client_ssl } ssl_encryption_questions__advanced { value yes } ssl_encryption_questions__help { value hide } monitor__http_version { value http11 } pool__pool_to_use { value /Common/$${applicationPoolName} } }}


# WARNING: If creating a user via startup script, remember to change the password as soon as you login or dispose after provisioning.
# tmsh delete auth user $${adminUsername}

############ END CUSTOM HIGH CONFIG ############

tmsh save /sys config
date
echo "FINISHED STARTUP SCRIPT"
