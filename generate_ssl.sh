#!/bin/bash

# Copyright (c) 2015 Dell Inc. or its subsidiaries. All Rights Reserved.
#
# This software contains the intellectual property of Dell Inc. or is licensed to Dell Inc. from third parties.
# Use of this software and the intellectual property contained therein is expressly limited to the terms and
# conditions of the License Agreement under which it is provided by or on behalf of Dell Inc. or its subsidiaries.

curr_user=$(whoami)
if [ $curr_user != "root" ]; then
    echo "Error: Generate SSL certification need root permission, exit."
    exit 1
fi

if [ ! $1 ]; then
    echo "Generate VxRail Manager SSL certification with FQDN before Firstrun."
    echo "Usage: $0 VXM_FQDN "
    exit 2
fi

day1_state=$(curl -k https://127.0.0.1/rest/vxm/private/v1/system/initialize/state)
day1_state=$(echo $day1_state | grep "\"state\":[ ]*\"NOT_CONFIGURED\"")
if [ -z "$day1_state" ]; then
    echo "Error: Current state is not NOT_CONFIGURED, exit."
    exit 3
fi

fqdn=$1
check_fqdn=$(echo "$fqdn" | grep -P "^(?=^.{3,255}$)[a-zA-Z0-9][-a-zA-Z0-9]{0,62}(\.[a-zA-Z0-9][-a-zA-Z0-9]{0,62})+$")
if [ -z "$check_fqdn" ]; then
    echo "Error: $fqdn is not a valid FQDN, exit."
    exit 4
fi

ssl_path="/etc/vmware-marvin/ssl"
cnf="$ssl_path/ca.cnf"

has_v3_req=$(grep "^\[ v3_req \]$" $cnf)
has_req_distinguished_name=$(grep "^\[ req_distinguished_name \]$" $cnf)
if [ -z "$has_v3_req" -o -z "$has_req_distinguished_name" ]; then
    echo "Error: $cnf is not a valid config file, exit."
    exit 5
fi

echo "Generate VxRail Manager SSL certification ..."
has_alt_names=$(grep "^\[ alt_names \]$" $cnf)
if [ -n "$has_alt_names" ]; then
    has_dns_1=$(grep "^DNS\.1[ ]*=.*" $cnf)
    if [ -n "$has_dns_1" ]; then
        sed -i "s/^DNS\.1[ ]*=.*/DNS\.1 = $fqdn/g" $cnf
    else
        sed -i "s/^\[ alt_names \]$/\[ alt_names \]\nDNS\.1 = $fqdn/g" $cnf
    fi
else
    echo "" >> $cnf
    echo "" >> $cnf
    echo "[ alt_names ]" >> $cnf
    echo "DNS.1 = $fqdn" >> $cnf
fi

has_subject_alt_name=$(grep "^subjectAltName[ ]*=.*" $cnf)
if [ -n "$has_subject_alt_name" ]; then
    sed -i "s/^subjectAltName[ ]*=.*/subjectAltName = @alt_names/g" $cnf
else
    sed -i "s/^\[ v3_req \]$/\[ v3_req \]\nsubjectAltName = @alt_names/g" $cnf
fi

has_common_name=$(grep "^commonName[ ]*=.*" $cnf)
if [ -n "$has_common_name" ]; then
    sed -i "s/^commonName[ ]*=.*/commonName = $fqdn/g" $cnf
else
    sed -i "s/^\[ req_distinguished_name \]$/\[ req_distinguished_name \]\ncommonName = $fqdn/g" $cnf
fi

sed -i "/^keyUsage[ ]*=.*/d" $cnf

env OPENSSL_FIPS=1 openssl-1.0.2 req -config $ssl_path/ca.cnf -new -key $ssl_path/server.key -out $ssl_path/server.csr
env OPENSSL_FIPS=1 openssl-1.0.2 x509 -req -days 810 -sha512 -in $ssl_path/server.csr -signkey $ssl_path/server.key -out $ssl_path/server.crt -extensions v3_req -extfile $ssl_path/ca.cnf
chmod 640 $ssl_path/server.key
chgrp pivotal $ssl_path/server.key

cp $ssl_path/server.crt $ssl_path/rootcert.crt
chmod 644 $ssl_path/rootcert.crt
env OPENSSL_FIPS=1 openssl-1.0.2 pkcs12 -export -out $ssl_path/server.pfx -inkey $ssl_path/server.key -in $ssl_path/server.crt -CAfile $ssl_path/rootcert.crt -chain -password pass:testpassword

echo "Reload api-gateway ..."
container_id=$(docker ps -q -f "name=func_api-gateway")
if [ -z "$container_id" ]; then
    echo "Error: Can not found docker container: func_api-gateway, exit."
    exit 6
fi
docker exec -u root $container_id bash /usr/local/bin/generate_crt.sh
docker exec -u root $container_id /usr/sbin/nginx -s reload

echo "Set skip re-generate SSL certification in Firstrun ..."
workflow_in_container="/home/app/workflow/workflow_day1_bringup.json"
updated_workflow="/var/lib/vxrail/ms_day1_bringup/workflow_day1_bringup.json"
docker cp $(docker ps -q -f "name=func_ms-day1-bringup"):$workflow_in_container $updated_workflow
sed -i "s/http:\/\/api-gateway:8080\/rest\/vxm\/internal\/operation\/v1\/vxm\/system\/cert\/update\/execute/http:\/\/ms-day1-bringup:5000\/echo/g" $updated_workflow
docker service update --mount-add type=bind,source=$updated_workflow,target=$workflow_in_container func_ms-day1-bringup

echo "===================================================================="
echo "Congratulation: Generate SSL certification with FQDN: $fqdn success."
echo "===================================================================="
