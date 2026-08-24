#!/usr/bin/env bash
set -euo pipefail

HOST_IP="192.168.56.150"
echo "start - install gitlab - $HOST_IP"

# 1. GitLab 설치 중 locale과 interactive prompt 문제를 방지합니다.
echo 'debconf debconf/frontend select Noninteractive' | sudo debconf-set-selections
sudo locale-gen --purge en_US.UTF-8
sudo sh -c 'echo "LANG=en_US.UTF-8\nLANGUAGE=en_US.UTF-8\nLC_ALL=en_US.UTF-8\nLC_CTYPE=en_US.UTF-8" > /etc/default/locale'

# 2. GitLab 설치에 필요한 기본 패키지를 설치합니다.
sudo apt-get update -qq >/dev/null
sudo apt-get install -qq -y vim git wget curl >/dev/null

# 3. GitLab CE apt repository를 등록합니다.
curl -sS https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | sudo bash

# 4. GitLab CE 패키지를 설치합니다.
sudo apt-get install -y gitlab-ce

# 5. GitLab 외부 URL을 VM private IP와 9999 포트로 설정합니다.
sudo sed -i 's|external_url \x27http://gitlab.example.com\x27|external_url \x27http://'"$HOST_IP"':9999\x27|g' /etc/gitlab/gitlab.rb

sudo tee -a /etc/gitlab/gitlab.rb > /dev/null <<'EOF'

# 6. 로컬 VM 리소스에 맞게 GitLab worker 수를 줄입니다.
puma['worker_processes'] = 2
sidekiq['max_concurrency'] = 10

# 7. 과제에 필요 없는 부가 서비스를 꺼서 메모리 사용량을 줄입니다.
prometheus_monitoring['enable'] = false
alertmanager['enable'] = false
node_exporter['enable'] = false
redis_exporter['enable'] = false
postgres_exporter['enable'] = false
gitlab_exporter['enable'] = false
gitlab_pages['enable'] = false
EOF

# 8. GitLab 설정을 적용하고 서비스를 시작합니다.
sudo gitlab-ctl reconfigure

echo "---------END - install gitlab---------"
echo "The initial root password is intentionally not printed or copied."
