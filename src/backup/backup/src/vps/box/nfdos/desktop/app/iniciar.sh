#!/bin/bash

cd /var/lib/neoricalex

git config pull.rebase true
git config rebase.autoStash true
git pull origin master

IP_MSG="$(curl --no-progress-meter http://ifconfig.io 2>&1)"
STATUS=$? 

if [ $STATUS -ne 0 ]; then
    MESSAGE="Oups! Ocorreu um erro [ $IP_MSG ]"
else
    MESSAGE="Parece bom! O IP Público é: $IP_MSG"
fi
echo $MESSAGE

exit 0

