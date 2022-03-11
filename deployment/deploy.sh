#!/bin/bash

# Deploy Jetstack cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install   cert-manager jetstack/cert-manager   --namespace cert-manager   --create-namespace   --version v1.7.1 --set installCRDs=true

# Deploy consul for vault
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
# TODO: fill helm-consul-values.yml
helm install -n cert-manager consul hashicorp/consul --values helm-consul-values.yml
# TODO: wait for consul to be ready

# Set default namespace
kubectl config set-context --current --namespace=cert-manager

# Deploy vault
#helm repo add hashicorp https://helm.releases.hashicorp.com
#helm repo update
# TODO: fill helm-vault-values.yml
helm install vault hashicorp/vault --values helm-vault-values.yml

# Unseal vault
kubectl exec vault-0 -- vault status
kubectl exec vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > cluster-keys.json
VAULT_UNSEAL_KEY=$(cat cluster-keys.json | jq -r ".unseal_keys_b64[]")
kubectl exec vault-0 -- vault operator unseal $VAULT_UNSEAL_KEY
kubectl exec vault-1 -- vault operator unseal $VAULT_UNSEAL_KEY
kubectl exec vault-2 -- vault operator unseal $VAULT_UNSEAL_KEY

# Deploy test webapp
# TODO: fill deployment-01-webapp.yml
kubectl apply -f deployment-01-webapp.yml

# Enable PKI engine in vault
kubectl exec -ti vault-0 -- vault login # root token from cluster-keys.json
kubectl exec vault-0 -- vault secrets enable pki
kubectl exec vault-0 -- vault secrets tune -max-lease-ttl=8760h pki
kubectl exec vault-0 -- vault write pki/root/generate/internal \
    common_name=example.com \
    ttl=8760h
kubectl exec vault-0 -- vault write pki/config/urls \
    issuing_certificates="http://127.0.0.1:8200/v1/pki/ca" \
    crl_distribution_points="http://127.0.0.1:8200/v1/pki/crl"
kubectl exec vault-0 -- vault write pki/roles/cert-manager \
    allowed_domains=example.com \
    allow_subdomains=true \
    max_ttl=72h
kubectl exec vault-0 -- vault write pki/issue/cert-manager \
    common_name=www.example.com

# Enable intermediate PKI in vault
kubectl exec vault-0 -- vault secrets enable -path=pki_int pki
kubectl exec vault-0 -- vault secrets tune -max-lease-ttl=43800h pki_int
kubectl exec vault-0 -- vault write pki_int/intermediate/generate/internal common_name="example.com Intermediate Authority" ttl=43800h -format=json | jq -r .data.csr > ./pki_int.csr
kubectl cp ./pki_int.csr cert-manager/vault-0:/home/vault/
kubectl exec vault-0 -- vault write pki/root/sign-intermediate csr=@/home/vault/pki_int.csr format=pem_bundle ttl=43800h -format=json | jq -r .data.certificate > ./pki_int.pem
kubectl cp ./pki_int.pem cert-manager/vault-0:/home/vault/
kubectl exec vault-0 -- vault write pki_int/intermediate/set-signed certificate=@/home/vault/pki_int.pem
kubectl exec vault-0 -- vault write pki_int/config/urls issuing_certificates="http://127.0.0.1:8200/v1/pki_int/ca" crl_distribution_points="http://127.0.0.1:8200/v1/pki_int/crl"
kubectl exec vault-0 -- vault write pki_int/roles/cert-manager \
    allowed_domains=example.com \
    allow_subdomains=true max_ttl=72h

# Add cert-manager policy in vault
cat << ECHO > ./pki_int-policy.hcl
path "pki_int/sign/cert-manager" {
    capabilities = ["update"]
}
ECHO
kubectl cp ./pki_int-policy.hcl cert-manager/vault-0:/home/vault/
kubectl exec vault-0 -- vault policy write cert-manager ~/pki_int-policy.hcl

# Enable Kubernetes auth method in vault
kubectl exec vault-0 -- vault auth enable kubernetes
kubectl exec vault-0 -- vault write auth/kubernetes/config \
    kubernetes_host=https://$(kubectl exec -ti vault-0 -- sh -c 'echo $KUBERNETES_SERVICE_HOST'):$(kubectl exec -ti vault-0 -- sh -c 'echo $KUBERNETES_SERVICE_PORT')
kubectl exec vault-0 -- vault write auth/kubernetes/role/cert-manager \
    bound_service_account_names=cert-manager \
    bound_service_account_namespaces=cert-manager \
    policies=cert-manager \
    ttl=1h

# Add Kubernetes Role
# TODO: fill cert-manager-role.yml
kubectl apply -f cert-manager-role.yml

# TODO: acquire cert-manager role secret name and add to vault-issuer-kubernetes.yml

# Add vault as an Issuer
# TODO: fill vault-issuer-kubernetes.yml
kubectl apply -f vault-issuer-kubernetes.yml
# TODO: wait for "Verified" status

# (Optional) Add Jetstack cmctl binary for easier certificate handling
#wget -c "https://github.com/cert-manager/cert-manager/releases/download/v1.7.1/cmctl-linux-amd64.tar.gz" -O - | tar -xz cmctl

# Create a new certificate
# TODO: fill example-certificate.yml
kubectl apply -f example-certificate.yml
