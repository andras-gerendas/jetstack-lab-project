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
kubectl exec -ti vault-0 -- sh
vault login # root token from cluster-keys.json
vault secrets enable pki
vault secrets tune -max-lease-ttl=8760h pki
vault write pki/root/generate/internal \
    common_name=my-website.com \
    ttl=8760h
vault write pki/config/urls \
    issuing_certificates="http://127.0.0.1:8200/v1/pki/ca" \
    crl_distribution_points="http://127.0.0.1:8200/v1/pki/crl"
vault write pki/roles/example-dot-com \
    allowed_domains=my-website.com \
    allow_subdomains=true \
    max_ttl=72h
vault write pki/issue/example-dot-com \
    common_name=www.my-website.com
vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=43800h pki_int
vault write pki_int/intermediate/generate/internal common_name="myvault.com Intermediate Authority" ttl=43800h
vault write pki_int/config/urls issuing_certificates="http://127.0.0.1:8200/v1/pki_int/ca" crl_distribution_points="http://127.0.0.1:8200/v1/pki_int/crl"
vault write pki_int/roles/example-dot-com \
    allowed_domains=example.com \
    allow_subdomains=true max_ttl=72h

# Enable Kubernetes auth method in vault
kubectl exec -ti vault-0 -- sh
vault login # root token from cluster-keys.json
vault auth enable kubernetes
vault write auth/kubernetes/config \
    kubernetes_host=https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT
vault write auth/kubernetes/role/cert-manager \
    bound_service_account_names=cert-manager \
    bound_service_account_namespaces=cert-manager \
    policies=default \
    ttl=1h

# Add Kubernetes Role
# TODO: fill cert-manager-role.yml
kubectl apply -f cert-manager-role.yml

# Add vault as an Issuer
# TODO: fill vault-issuer-kubernetes.yml
kubectl apply -f vault-issuer-kubernetes.yml

