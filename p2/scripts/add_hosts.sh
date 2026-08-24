#!/bin/bash

# IP와 호스트네임 정의
IP="${1:-192.168.56.110}"
HOSTS=("app1.com" "app2.com" "app3.com")

# /etc/hosts에 추가
for HOST in "${HOSTS[@]}"; do
    # 이미 존재하는지 확인
    if grep -q "$IP $HOST" /etc/hosts; then
        echo "$HOST already exists in /etc/hosts"
    else
        # 추가
        echo "Adding $HOST to /etc/hosts"
        echo "$IP $HOST" | sudo tee -a /etc/hosts > /dev/null
    fi
done

echo "Hosts file updated!"
