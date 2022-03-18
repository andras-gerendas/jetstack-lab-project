#!/bin/bash

# Set default namespace
kubectl config set-context --current --namespace=cert-manager

# Deploy Jetstack cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager --create-namespace --version v1.7.1 --set installCRDs=true

# TODO: create bootstrap CA and certificates to initialize HTTPS connection between vault and cert-manager

# Deploy consul for vault
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
# TODO: fill helm-consul-values.yml
helm install consul hashicorp/consul --values helm-consul-values.yml
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

# Login and enable audit in vault
VAULT_ROOT_TOKEN=$(cat cluster-keys.json | jq -r ".root_token")
echo $VAULT_ROOT_TOKEN
kubectl exec -ti vault-0 -- vault login # root token in $VAULT_ROOT_TOKEN
kubectl exec vault-0 -- vault audit enable file file_path=/vault/vault_audit.log

# Enable PKI engine in vault
kubectl exec vault-0 -- vault secrets enable pki
kubectl exec vault-0 -- vault secrets tune -max-lease-ttl=8760h pki
kubectl exec vault-0 -- vault write pki/root/generate/internal \
    common_name="Vault PKI" \
    ttl=8760h
kubectl exec vault-0 -- vault write pki/config/urls \
    issuing_certificates="http://vault:8200/v1/pki/ca" \
    crl_distribution_points="http://vault:8200/v1/pki/crl"
kubectl exec vault-0 -- vault write pki/roles/cert-manager \
    allowed_domains=cluster.local \
    allow_subdomains=true \
    max_ttl=72h

# Enable intermediate PKI in vault
kubectl exec vault-0 -- vault secrets enable -path=pki_int pki
kubectl exec vault-0 -- vault secrets tune -max-lease-ttl=8760h pki_int
kubectl exec vault-0 -- vault write pki_int/intermediate/generate/internal common_name="Vault PKI Intermediate Authority" ttl=8760h -format=json | jq -r .data.csr > ./pki_int.csr
kubectl cp ./pki_int.csr cert-manager/vault-0:/home/vault/
kubectl exec vault-0 -- vault write pki/root/sign-intermediate csr=@/home/vault/pki_int.csr format=pem_bundle ttl=8760h -format=json | jq -r .data.certificate > ./pki_int.pem
kubectl exec vault-0 -- vault read pki/cert/ca -format=json | jq -r .data.certificate >> ./pki_int.pem
#openssl crl2pkcs7 -nocrl -certfile ./pki_int.pem | openssl pkcs7 -print_certs -text -noout
kubectl cp ./pki_int.pem cert-manager/vault-0:/home/vault/
kubectl exec vault-0 -- vault write pki_int/intermediate/set-signed certificate=@/home/vault/pki_int.pem
kubectl exec vault-0 -- vault write pki_int/config/urls issuing_certificates="http://vault:8200/v1/pki_int/ca" crl_distribution_points="http://vault:8200/v1/pki_int/crl"
kubectl exec vault-0 -- vault write pki_int/roles/cert-manager \
    allowed_domains=cluster.local \
    allow_subdomains=true allow_any_name=true max_ttl=72h

# Add cert-manager policy in vault
cat << ECHO > ./pki_int-policy.hcl
path "pki_int/sign/cert-manager" {
    capabilities = ["update"]
}
ECHO
kubectl cp ./pki_int-policy.hcl cert-manager/vault-0:/home/vault/
kubectl exec vault-0 -- vault policy write cert-manager /home/vault/pki_int-policy.hcl

# Enable Kubernetes auth method in vault
kubectl exec vault-0 -- vault auth enable kubernetes
kubectl exec vault-0 -- vault write auth/kubernetes/config \
    kubernetes_host=https://$(kubectl exec vault-0 -- sh -c 'echo $KUBERNETES_SERVICE_HOST'):$(kubectl exec vault-0 -- sh -c 'echo $KUBERNETES_SERVICE_PORT')
kubectl exec vault-0 -- vault write auth/kubernetes/role/cert-manager \
    bound_service_account_names=cert-manager \
    bound_service_account_namespaces=cert-manager \
    policies=cert-manager \
    ttl=1h

# Add vault as an Issuer
# TODO: fill vault-issuer-kubernetes.yml
sed "s/CERT-MANAGER-TOKEN-NAME/$(kubectl get secrets -o NAME | grep 'cert-manager-token' | sed 's/secret\///')/" vault-issuer-kubernetes-TEMPLATE.yml > vault-issuer-kubernetes.yml
kubectl apply -f vault-issuer-kubernetes.yml
# TODO: wait for "Verified" status

# (Optional) Add Jetstack cmctl binary for easier certificate handling
#wget -c "https://github.com/cert-manager/cert-manager/releases/download/v1.7.1/cmctl-linux-amd64.tar.gz" -O - | tar -xz cmctl

# Create a new server certificate
# TODO: fill server-certificate.yml
kubectl apply -f server-certificate.yml

# Deploy nginx server
# TODO: fill nginx-server.yml
kubectl apply -f nginx-server.yml

# Create a new client certificate
# TODO: fill client-certificate.yml
kubectl apply -f client-certificate.yml

# Deploy TLS client
# TODO: fill tls-client.yml
kubectl apply -f tls-client.yml

# Test server-client connection and certificates:
# TODO: determine tls-client pod name
kubectl exec -ti "$(kubectl get pod -o NAME | grep 'nginx-server' | sed 's/pod\///')" -c alpine -- bash
openssl x509 -in /etc/nginx/ssl/tls.crt -noout -text
openssl s_server -CAfile /etc/nginx/ssl/ca.crt -key /etc/nginx/ssl/tls.key -cert /etc/nginx/ssl/tls.crt -accept 81 -tls1_3 -verify 1 -www

kubectl exec -ti "$(kubectl get pod -o NAME | grep 'tls-client' | sed 's/pod\///')" -- bash
openssl x509 -in /etc/ssl/client-certs/tls.crt -noout -text
openssl s_client -connect nginx:443 </dev/null 2>/dev/null | openssl x509 -inform pem -text
curl --cert /etc/ssl/client-certs/tls.crt --key /etc/ssl/client-certs/tls.key --cacert /etc/ssl/client-certs/ca.crt -vv https://nginx:443
