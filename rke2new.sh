#!/bin/bash

### Configuration Variables ###
SSH_USER=$(whoami)                               # SSH user for nodes
script_path="/home/$(whoami)/.val"
source "$script_path"
CONTROL_PLANE_VIP="$VIP"                        # VIP for Kubernetes API
METALLB_IP_RANGE="$METALLB_IP_RANGE"            # IPs for MetalLB
#RKE2_TOKEN="$RKE2_TOKEN"                        # Cluster join token
INTERFACE="$INTERFACE"                          # Network interface

# Domain/Certificate Settings
DOMAIN_NAME="${DOMAIN_NAME}"                    # Your domain
WILDCARD_DOMAIN="*.${DOMAIN_NAME}"              # Wildcard cert
RANCHER_HOSTNAME="rancher.${DOMAIN_NAME}"       # Rancher URL
CERTMANAGER_EMAIL="$email"                      # For Let's Encrypt
CLOUDFLARE_API_TOKEN="$CLOUDFLARE_API_TOKEN"    # Cloudflare DNS token

# Component Versions (Stable as of July 2024)
RKE2_VERSION="v1.28.8+rke2r1"                   # Kubernetes 1.28
KUBE_VIP_VERSION="v0.6.4"                       # VIP management
METALLB_VERSION="v0.13.12"                      # LoadBalancer
CILIUM_VERSION="1.15.3"                         # CNI + Hubble
CERT_MANAGER_VERSION="v1.13.3"                  # Certificate management
RANCHER_VERSION="v2.8.5"                        # Kubernetes dashboard

# Generate secure token (64 chars)
RKE2_TOKEN=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)

# Component Versions (Stable)
RKE2_VERSION="v1.28.8+rke2r1"
KUBE_VIP_VERSION="v0.6.4"
METALLB_VERSION="v0.13.12"
CILIUM_VERSION="1.15.3"
CERT_MANAGER_VERSION="v1.13.3"
RANCHER_VERSION="v2.8.5"

# Node IPs
MASTERS=("192.168.20.31" "192.168.20.32" "192.168.20.33")
WORKERS=("192.168.20.34" "192.168.20.35")
ALL_NODES=("${MASTERS[@]}" "${WORKERS[@]}")

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

### --- Cluster Setup --- ###

# Generate SSH key if missing
[ ! -f ~/.ssh/id_rsa ] && ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""

# Copy SSH key to all nodes
for NODE in "${ALL_NODES[@]}"; do
  ssh-copy-id -i ~/.ssh/id_rsa.pub ${SSH_USER}@${NODE}
done

# Install prerequisites
for NODE in "${ALL_NODES[@]}"; do
  ssh ${SSH_USER}@${NODE} <<EOF
    sudo apt-get update
    sudo apt-get install -y curl apt-transport-https
EOF
done

### --- RKE2 Installation --- ###

FIRST_MASTER=${MASTERS[0]}

# kube-vip manifest with critical fixes
KUBE_VIP_MANIFEST=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-vip
    image: ghcr.io/kube-vip/kube-vip:${KUBE_VIP_VERSION}
    args: ["manager"]
    env:
    - name: vip_arp
      value: "true"
    - name: vip_interface
      value: "${INTERFACE}"
    - name: vip_address
      value: "${CONTROL_PLANE_VIP}"
    securityContext:
      capabilities:
        add: ["NET_ADMIN", "NET_RAW"]
EOF
)

# First master configuration
ssh ${SSH_USER}@${FIRST_MASTER} <<EOF
  sudo mkdir -p /etc/rancher/rke2
  cat <<CONFIG | sudo tee /etc/rancher/rke2/config.yaml
token: ${RKE2_TOKEN}
server: https://${CONTROL_PLANE_VIP}:9345
cluster-init: true
disable: rke2-canal
tls-san:
  - "${CONTROL_PLANE_VIP}"
  - "${FIRST_MASTER}"
write-kubeconfig-mode: "0644"
CONFIG

  sudo mkdir -p /var/lib/rancher/rke2/server/manifests
  echo '${KUBE_VIP_MANIFEST}' | sudo tee /var/lib/rancher/rke2/server/manifests/kube-vip.yaml
EOF

# Install RKE2 with retries
for i in {1..3}; do
  ssh ${SSH_USER}@${FIRST_MASTER} "curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${RKE2_VERSION} sudo sh -"
  [ $? -eq 0 ] && break
  echo "Retry $i/3: RKE2 installation..."
  sleep 10
done

# Start services with verification
ssh ${SSH_USER}@${FIRST_MASTER} <<EOF
  sudo systemctl enable rke2-server.service
  sudo systemctl start rke2-server.service
EOF

# Wait for VIP assignment
echo "Waiting for VIP ${CONTROL_PLANE_VIP} to be assigned..."
for i in {1..30}; do
  if ssh ${SSH_USER}@${FIRST_MASTER} "ip a show ${INTERFACE} | grep ${CONTROL_PLANE_VIP}"; then
    echo "VIP successfully assigned"
    break
  fi
  sleep 5
done

### --- Configure Management Node --- ###

# Install kubectl
KUBE_VERSION=$(echo "${RKE2_VERSION}" | cut -d'+' -f1 | sed 's/v//')
curl -LO "https://dl.k8s.io/release/v${KUBE_VERSION}/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# Configure kubeconfig
mkdir -p ~/.kube
ssh ${SSH_USER}@${FIRST_MASTER} "sudo cat /etc/rancher/rke2/rke2.yaml" | \
  sed "s/127.0.0.1/${CONTROL_PLANE_VIP}/g" > ~/.kube/config
chmod 600 ~/.kube/config

# Add kubectl to PATH
echo 'export PATH=$PATH:/usr/local/bin' >> ~/.bashrc
source ~/.bashrc

### --- Join Nodes --- ###

# Other masters
OTHER_MASTERS=("${MASTERS[@]:1}")
for NODE in "${OTHER_MASTERS[@]}"; do
  ssh ${SSH_USER}@${NODE} <<EOF
    sudo mkdir -p /etc/rancher/rke2
    cat <<CONFIG | sudo tee /etc/rancher/rke2/config.yaml
token: ${RKE2_TOKEN}
server: https://${CONTROL_PLANE_VIP}:9345
disable: rke2-canal
tls-san:
  - "${CONTROL_PLANE_VIP}"
  - "${NODE}"
CONFIG
    curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${RKE2_VERSION} sudo sh -
    sudo systemctl enable rke2-server.service
    sudo systemctl start rke2-server.service
EOF
done

# Workers
for NODE in "${WORKERS[@]}"; do
  ssh ${SSH_USER}@${NODE} <<EOF
    sudo mkdir -p /etc/rancher/rke2
    cat <<CONFIG | sudo tee /etc/rancher/rke2/config.yaml
server: https://${CONTROL_PLANE_VIP}:9345
token: ${RKE2_TOKEN}
CONFIG
    curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${RKE2_VERSION} sudo sh -s - agent
    sudo systemctl enable rke2-agent.service
    sudo systemctl start rke2-agent.service
EOF
done

echo "Waiting 2 minutes for nodes to join..."
sleep 120

### --- Install Cilium --- ###
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version ${CILIUM_VERSION} \
  --namespace kube-system \
  --set kubeProxyReplacement=strict \
  --set hubble.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.relay.enabled=true

### --- Install MetalLB --- ###
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml
sleep 60

kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_IP_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
EOF

### --- Cert-Manager with Cloudflare DNS --- ###
# server: https://acme-v02.api.letsencrypt.org/directory #---use this for prodcution
# server: server: https://acme-staging-v02.api.letsencrypt.org/directory  #---use this for staging/testing
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml
sleep 60

kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token=${CLOUDFLARE_API_TOKEN}

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: ${CERTMANAGER_EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory 
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token
EOF

### --- Install Rancher --- ###
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
kubectl create namespace cattle-system

helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --version ${RANCHER_VERSION} \
  --set hostname=${RANCHER_HOSTNAME} \
  --set bootstrapPassword=admin \
  --set ingress.tls.source=secret \
  --set tls=external \
  --set ingress.extraAnnotations."cert-manager\.io\/cluster-issuer"=letsencrypt-prod

### --- Final Checks --- ###
echo -e "\n\033[1;32m=== Deployment Complete ===\033[0m"
echo "Control Plane VIP: ${CONTROL_PLANE_VIP}"
echo "Rancher URL: https://${RANCHER_HOSTNAME}"
echo "Default credentials: admin / admin"
echo -e "\nVerify components:"
echo "kubectl get nodes"
echo "kubectl get pods -A"