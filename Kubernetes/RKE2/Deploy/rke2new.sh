#!/bin/bash

### Configuration Variables ###
SSH_USER=$(whoami)                               # SSH user for nodes
script_path="/home/$(whoami)/.val"
source "$script_path"
CONTROL_PLANE_VIP="$VIP"                        # VIP for Kubernetes API
METALLB_IP_RANGE="$METALLB_IP_RANGE"            # IPs for MetalLB
#RKE2_TOKEN="$RKE2_TOKEN"                        # Cluster join token
INTERFACE="$INTERFACE"                          # Network interface
CERTNAME=id_rsa

# Domain/Certificate Settings
DOMAIN_NAME="${DOMAIN_NAME}"                    # Your domain
WILDCARD_DOMAIN="*.${DOMAIN_NAME}"              # Wildcard cert
RANCHER_HOSTNAME="rancher.${DOMAIN_NAME}"       # Rancher URL
CERTMANAGER_EMAIL="$email"                      # For Let's Encrypt
CLOUDFLARE_API_TOKEN="$CLOUDFLARE_API_TOKEN"    # Cloudflare DNS token

# Component Versions
RKE2_VERSION="v1.32.3+rke2r1"                   # Kubernetes 1.28
KUBE_VIP_VERSION="v0.9.1"                       # VIP management
METALLB_VERSION="v0.13.12"                      # LoadBalancer
CILIUM_VERSION="1.15.3"                         # CNI + Hubble
CERT_MANAGER_VERSION="v1.13.3"                  # Certificate management
RANCHER_VERSION="v2.8.5"                        # Kubernetes dashboard

# Generate secure token (64 chars)
RKE2_TOKEN=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)

# Node IPs
MASTERS=("192.168.20.31" "192.168.20.32" "192.168.20.33")
WORKERS=("192.168.20.34" "192.168.20.35")
ALL_NODES=("${MASTERS[@]}" "${WORKERS[@]}")
MANAGEMENT=192.168.20.5

FIRST_MASTER=${MASTERS[0]}
SECOND_MASTER=${MASTERS[1]}
THIRD_MASTER=${MASTERS[2]}

### --- Pre-Flight Checks --- ###

# Verify interface exists on all nodes
for NODE in "${ALL_NODES[@]}"; do
  echo "Checking ${INTERFACE} on ${NODE}"
  if ! ssh ${SSH_USER}@${NODE} "ip link show ${INTERFACE}"; then
    echo "ERROR: Interface ${INTERFACE} missing on ${NODE}"
    exit 1
  fi
done

# Check VIP availability
if ping -c 1 -W 1 ${CONTROL_PLANE_VIP} &>/dev/null; then
  echo "ERROR: ${CONTROL_PLANE_VIP} is already in use!"
  exit 1
fi

# make kube folder to run kubectl later
mkdir ~/.kube

# Generate SSH key if missing
[ ! -f ~/.ssh/id_rsa ] && ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""

# Install Kubectl on management server, if not already present
if ! command -v kubectl version &> /dev/null
then
    echo -e " \033[31;5mKubectl not found, installing\033[0m"
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
else
    echo -e " \033[32;5mKubectl already installed\033[0m"
fi

# create the rke2 config file
sudo mkdir -p /etc/rancher/rke2
  cat <<CONFIG | sudo tee /etc/rancher/rke2/config.yaml
token: ${RKE2_TOKEN}
cni:
  - cilium
tls-san:
  - "${CONTROL_PLANE_VIP}"
  - "${MASTERS[0]}"
  - "${MASTERS[1]}"
  - "${MASTERS[2]}"
write-kubeconfig-mode: "0644"
disable:
  - rke2-ingress-nginx
disable-kube-proxy: "true"
CONFIG

# Install the kube-vip deployment into rke2's self-installing manifest folder
sudo mkdir -p /var/lib/rancher/rke2/server/manifests
curl -sO https://raw.githubusercontent.com/ksbhatti/fromHereOn/refs/heads/main/Kubernetes/RKE2/Deploy/kube-vip
cat kube-vip | sed 's/$interface/'$INTERFACE'/g; s/$vip/'$CONTROL_PLANE_VIP'/g' > $HOME/kube-vip.yaml
sudo mv kube-vip.yaml /var/lib/rancher/rke2/server/manifests/kube-vip.yaml
sudo cp /var/lib/rancher/rke2/server/manifests/kube-vip.yaml ~/kube-vip.yaml
sudo chown $user:$user kube-vip.yaml

# copy config.yaml from rancher directory
sudo cp /etc/rancher/rke2/config.yaml ~/config.yaml

# update path with rke2-binaries
echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> ~/.bashrc ; echo 'export PATH=${PATH}:/var/lib/rancher/rke2/bin' >> ~/.bashrc ; echo 'alias k=kubectl' >> ~/.bashrc ; source ~/.bashrc ;


# Step 2: Copy kube-vip.yaml and certs to all masters
for NODE in "${ALL_NODES[@]}"; do
  ssh-copy-id -i ~/.ssh/id_rsa.pub ${SSH_USER}@${NODE}
  scp -i ~/.ssh/$CERTNAME $HOME/config.yaml $user@$NODE:~/config.yaml
  scp -i ~/.ssh/$CERTNAME $HOME/kube-vip.yaml $user@$NODE:~/kube-vip.yaml
  echo -e " \033[32;5mCert and config.yaml files Copied successfully!\033[0m"
done

### --- Cluster Setup --- ###


ssh -tt ${SSH_USER}@${MASTERS[0]} sudo su <<EOF
mkdir -p /var/lib/rancher/rke2/server/manifests
mv kube-vip.yaml /var/lib/rancher/rke2/server/manifests/kube-vip.yaml
mkdir -p /etc/rancher/rke2
mv config.yaml /etc/rancher/rke2/config.yaml
echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> ~/.bashrc ; echo 'export PATH=${PATH}:/var/lib/rancher/rke2/bin' >> ~/.bashrc ; echo 'alias k=kubectl' >> ~/.bashrc ; source ~/.bashrc ;
curl -LJO https://raw.githubusercontent.com/JamesTurland/JimsGarage/main/Kubernetes/RKE2-Cilium/rke2-cilium-config.yaml
cat rke2-cilium-config.yaml | sed 's/<KUBE_API_SERVER_IP>/'${MASTERS[0]}'/g' > rke2-cilium-config-update.yaml
cp rke2-cilium-config-update.yaml /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
"curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${RKE2_VERSION} sudo sh -"
systemctl enable rke2-server.service
systemctl start rke2-server.service
touch ~/.ssh/config
echo "StrictHostKeyChecking no" > ~/.ssh/config
scp -i /home/$user/.ssh/$CERTNAME /etc/rancher/rke2/rke2.yaml $user@$MANAGEMENT:~/.kube/rke2.yaml
exit
EOF
echo -e " \033[32;5mMaster1 Completed\033[0m"

# Set kube config location
sudo cat ~/.kube/rke2.yaml | sed 's/127.0.0.1/'${MASTERS[0]}'/g' > $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
export KUBECONFIG=${HOME}/.kube/config
sudo cp ~/.kube/config /etc/rancher/rke2/rke2.yaml
kubectl get nodes

# Wait for VIP assignment
#echo "Waiting for VIP ${CONTROL_PLANE_VIP} to be assigned..."
#for i in {1..30}; do
#  if ssh ${SSH_USER}@${FIRST_MASTER} "ip a show ${INTERFACE} | grep ${CONTROL_PLANE_VIP}"; then
 #   echo "VIP successfully assigned"
  #  break
 # fi
#  sleep 5
#done

### --- Join Nodes --- ###

# Other masters
OTHER_MASTERS=("${MASTERS[@]:1}")
for NODE in "${OTHER_MASTERS[@]}"; do
  ssh ${SSH_USER}@${NODE} <<EOF
    mkdir -p /etc/rancher/rke2
    mkdir -p /var/lib/rancher/rke2/server/manifests
    cat <<CONFIG | sudo tee /etc/rancher/rke2/config.yaml
token: ${RKE2_TOKEN}
server: https://${MASTERS[0]}:9345
cni:
  - cilium
tls-san:
  - "${CONTROL_PLANE_VIP}"
  - "${MASTERS[0]}"
  - "${MASTERS[1]}"
  - "${MASTERS[2]}"
write-kubeconfig-mode: "0644"
disable:
  - rke2-ingress-nginx
disable-kube-proxy: "true"
CONFIG
  curl -LJO https://raw.githubusercontent.com/JamesTurland/JimsGarage/main/Kubernetes/RKE2-Cilium/rke2-cilium-config.yaml
  cat rke2-cilium-config.yaml | sed 's/<KUBE_API_SERVER_IP>/'${MASTERS[0]}'/g' > rke2-cilium-config-update.yaml
  cp rke2-cilium-config-update.yaml /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
  curl -sfL https://get.rke2.io | sh -
  systemctl enable rke2-server.service
  systemctl start rke2-server.service
  exit
EOF
done

kubectl get nodes

# Workers
for NODE in "${WORKERS[@]}"; do
  ssh ${SSH_USER}@${NODE} <<EOF
    sudo mkdir -p /etc/rancher/rke2
    cat <<CONFIG | sudo tee /etc/rancher/rke2/config.yaml
server: https://${CONTROL_PLANE_VIP}:9345
token: ${RKE2_TOKEN}
node-label:
  - worker=true
  - longhorn=true
CONFIG
    curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh -
    sudo systemctl enable rke2-agent.service
    sudo systemctl start rke2-agent.service
    exit
EOF
 echo -e " \033[32;5mMaster node joined successfully!\033[0m"
done

echo "Waiting 2 minutes for nodes to join..."
sleep 120
kubectl get nodes


# Step 8: Install Rancher (Optional - Delete if not required)
#Install Helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# Add Rancher Helm Repo & create namespace
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
kubectl create namespace cattle-system

# Install Cert-Manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.crds.yaml
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
--namespace cert-manager \
--create-namespace \
--version v1.13.2
kubectl get pods --namespace cert-manager

# Install Rancher
helm install rancher rancher-latest/rancher \
 --namespace cattle-system \
 --set hostname=rancher.my.org \
 --set bootstrapPassword=admin
kubectl -n cattle-system rollout status deploy/rancher
kubectl -n cattle-system get deploy rancher

# Add Rancher LoadBalancer
kubectl get svc -n cattle-system
kubectl expose deployment rancher --name=rancher-lb --port=443 --type=LoadBalancer -n cattle-system
while [[ $(kubectl get svc -n cattle-system 'jsonpath={..status.conditions[?(@.type=="Pending")].status}') = "True" ]]; do
   sleep 5
   echo -e " \033[32;5mWaiting for LoadBalancer to come online\033[0m" 
done
kubectl get svc -n cattle-system

echo -e " \033[32;5mAccess Rancher from the IP above - Password is admin!\033[0m"

# Update Kube Config with VIP IP
sudo cat /etc/rancher/rke2/rke2.yaml | sed 's/'$master1'/'$vip'/g' > /etc/rancher/rke2/rke2.yaml