include .env

.PHONY: help
help: ## Show available commands
	@echo "Commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: dependency
dependency:
	@if kubectl oidc-login --version >/dev/null 2>&1; then \
		echo "✅ Kubectl oidc-login is installed"; \
	else \
		echo "❌ Kubectl oidc-login is not installed"; \
		exit 1; \
	fi

.PHONY: root-ca
root-ca: ## Create root CA
	@mkdir -p ./certs
	@openssl genrsa -out ./certs/root-ca.key 4096;
	@openssl req -x509 -new -key ./certs/root-ca.key -sha256 -days 3650 -out ./certs/root-ca.pem \
		-subj "/CN=AI Platform Root CA/O=AI Platform/L=Gangnam/ST=Seoul/C=KR" \
		-addext "basicConstraints=critical,CA:TRUE" \
		-addext "keyUsage=critical,keyCertSign,cRLSign";

.PHONY: csr
csr: ## Create CSR for *.${DOMAIN_HOST}
	@echo "📄 Creating CSR for *.${DOMAIN_HOST}..."
	@openssl genrsa -out ./certs/${CLUSTER_NAME}-key.pem 4096;
	@openssl req -new -key ./certs/${CLUSTER_NAME}-key.pem -out ./certs/${CLUSTER_NAME}.csr \
		-subj "/CN=*.${DOMAIN_HOST}/OU=Platform Infrastructure/O=AI Platform/L=Gangnam/ST=Seoul/C=KR" \
		-addext "subjectAltName=DNS:*.${DOMAIN_HOST},DNS:${DOMAIN_HOST},DNS:*.serving.${DOMAIN_HOST}"

.PHONY: sign-cert
sign-cert: ## Sign leaf certificate with Root CA
	@echo "✍️ Signing leaf certificate with Root CA..."
	@printf '%s\n' \
		'[ext]' \
		'basicConstraints=CA:FALSE' \
		'keyUsage=digitalSignature,keyEncipherment' \
		'extendedKeyUsage=serverAuth' \
		"subjectAltName=DNS:*.${DOMAIN_HOST},DNS:${DOMAIN_HOST},DNS:*.serving.${DOMAIN_HOST}" \
		> ./certs/${CLUSTER_NAME}-leaf.ext
	@openssl x509 -req -in ./certs/${CLUSTER_NAME}.csr -CA ./certs/root-ca.pem -CAkey ./certs/root-ca.key -CAcreateserial \
		-out ./certs/${CLUSTER_NAME}-cert.pem -days 825 -sha256 -extfile ./certs/${CLUSTER_NAME}-leaf.ext -extensions ext
	@cat ./certs/${CLUSTER_NAME}-cert.pem ./certs/root-ca.pem > ./certs/${CLUSTER_NAME}-chain.pem

.PHONY: deprecated-issue-cert
deprecated-issue-cert: ## Issue certificate
	@mkdir -p ./certs
	@openssl req -x509 -newkey rsa:4096 -keyout ./certs/${CLUSTER_NAME}-key.pem -out ./certs/${CLUSTER_NAME}-cert.pem \
		-days 365 -nodes \
		-subj "/CN=*.${DOMAIN_HOST}/OU=Platform Infrastructure/O=AI Platform/L=Gangnam/ST=Seoul/C=KR" \
		-addext "subjectAltName=DNS:*.${DOMAIN_HOST},DNS:${DOMAIN_HOST}";

.PHONY: deprecated-apply-cert
deprecated-apply-cert: ## Apply certificate
	@if [ "$$(uname)" = "Darwin" ] && [ -f ./certs/${CLUSTER_NAME}-cert.pem ]; then \
		echo "🍎 Updating certificate in macOS Keychain..."; \
		sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ./certs/${CLUSTER_NAME}-cert.pem && \
		echo "✅ Certificate updated in macOS System Keychain" || \
		echo "⚠️  Failed to update certificate in macOS Keychain (requires sudo)"; \
	elif [ "$$(uname)" != "Darwin" ]; then \
		echo "ℹ️  macOS certificate installation skipped (not macOS)"; \
	fi

.PHONY: apply-cert
apply-cert:
	@if [ "$$(uname)" = "Darwin" ] && [ -f ./certs/root-ca.pem ]; then \
		echo "🍎 Updating Root CA certificate in macOS Keychain..."; \
		sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ./certs/root-ca.pem && \
		echo "✅ Root CA certificate updated in macOS System Keychain" || \
		echo "⚠️  Failed to update Root CA certificate in macOS Keychain (requires sudo)"; \
	elif [ "$$(uname)" != "Darwin" ]; then \
		echo "ℹ️  macOS certificate installation skipped (not macOS)"; \
	fi

.PHONY: deprecated-cert
deprecated-cert: deprecated-issue-cert deprecated-apply-cert

.PHONY: cert
cert: root-ca csr sign-cert apply-cert ## Issue and apply certificate

.PHONY: deprecated-find-cert
deprecated-find-cert:
	@security find-certificate -c "${DOMAIN_HOST}" /Library/Keychains/System.keychain

.PHONY: find-cert
find-cert:
	@security find-certificate -c "AI Platform" /Library/Keychains/System.keychain

.PHONY: destroy-cert
destroy-cert: ## Open Keychain Access for manual certificate deletion
	@if [ "$$(uname)" = "Darwin" ]; then \
		echo "🗑️ Opening Keychain Access for manual deletion..."; \
		open -a "Keychain Access"; \
		echo "📋 Manual deletion steps:"; \
		echo "1. Select 'System' keychain (left sidebar)"; \
		echo "2. Select 'Certificates' category (top)"; \
		echo "3. Find '${DOMAIN_HOST}' certificate"; \
		echo "4. Select it and press Delete key"; \
		echo "5. Enter admin password when prompted"; \
	elif [ "$$(uname)" != "Darwin" ]; then \
		echo "ℹ️ macOS certificate deletion skipped (not macOS)"; \
	fi

.PHONY: test-cluster
test-cluster: ## Install test cluster
	@if ! k3d cluster list ${CLUSTER_NAME}; then \
	  k3d cluster create ${CLUSTER_NAME} \
	  --agents ${TEST_CLUSTER__WORKER_NODES} \
		--registry-config "registry.yaml" \
		--port "80:80@server:0:direct" \
		--port "443:443@server:0:direct" \
		--api-port ${KUBERNETES__APISERVER_HOST}:${KUBERNETES__APISERVER_PORT} \
		-i \
		--k3s-arg "--image=${TEST_CLUSTER__IMAGE}" \
		--k3s-arg '--disable=traefik@server:*' \
		--volume "$$(pwd)/certs:/tmp/${CLUSTER_NAME}-certs:ro" \
		--k3s-arg '--kube-apiserver-arg=oidc-issuer-url=${KUBERNETES__OIDC_ISSUER_URL}@server:*' \
		--k3s-arg '--kube-apiserver-arg=oidc-client-id=${KUBERNETES__OIDC_CLIENT_ID}@server:*' \
		--k3s-arg '--kube-apiserver-arg=oidc-username-claim=preferred_username@server:*' \
		--k3s-arg '--kube-apiserver-arg=oidc-groups-claim=groups@server:*' \
		--k3s-arg '--kube-apiserver-arg=oidc-ca-file=/tmp/${CLUSTER_NAME}-certs/${CLUSTER_NAME}-cert.pem@server:*' \
		--k3s-arg '--kube-apiserver-arg=authorization-mode=Node,RBAC@server:*'; \
	fi

.PHONY: deprecated-tls
deprecated-tls:
	@if [ ! -f "./certs/${CLUSTER_NAME}-cert.pem" ]; then \
		echo "❌ Certificate ${CLUSTER_NAME}-cert.pem does not exist"; \
		echo "Please run 'make cert' first to generate certificate chain"; \
		exit 1; \
	fi
	@if [ ! -f "./certs/${CLUSTER_NAME}-key.pem" ]; then \
		echo "❌ Key ${CLUSTER_NAME}-key.pem does not exist"; \
		exit 1; \
	fi
	@kubectl create secret tls ${CLUSTER_NAME}-tls \
		--cert=./certs/${CLUSTER_NAME}-cert.pem \
		--key=./certs/${CLUSTER_NAME}-key.pem \
		-n ${ISTIO__NAMESPACE}

.PHONY: tls
tls:
	@if [ ! -f "./certs/${CLUSTER_NAME}-chain.pem" ]; then \
		echo "❌ Certificate chain ${CLUSTER_NAME}-chain.pem does not exist"; \
		echo "Please run 'make cert' first to generate certificate chain"; \
		exit 1; \
	fi
	@if [ ! -f "./certs/${CLUSTER_NAME}-key.pem" ]; then \
		echo "❌ Key ${CLUSTER_NAME}-key.pem does not exist"; \
		exit 1; \
	fi
	@kubectl create secret tls ${CLUSTER_NAME}-tls \
		--cert=./certs/${CLUSTER_NAME}-chain.pem \
		--key=./certs/${CLUSTER_NAME}-key.pem \
		-n ${ISTIO__NAMESPACE}

.PHONY: copy-tls
copy-tls: ## Copy TLS secret from istio-system to gitea namespace
	@echo "📋 Copying TLS secret from istio-system to ${namespace} namespace..."
	@kubectl get secret ${CLUSTER_NAME}-tls -n ${ISTIO__NAMESPACE} -o yaml | \
		sed 's/namespace: ${ISTIO__NAMESPACE}/namespace: ${namespace}/' | \
		kubectl apply -f -
	@echo "✅ TLS secret copied to ${namespace} namespace"

.PHONY: ca
ca: ## Create CA secret
	-@kubectl create namespace ${namespace}
	@kubectl create secret generic ${CLUSTER_NAME}-ca \
		-n ${namespace} \
		--from-file=ca.crt=./certs/${CLUSTER_NAME}-cert.pem

# --k3s-arg '--kube-apiserver-arg=oidc-ca-file=/tmp/${CLUSTER_NAME}-certs/${CLUSTER_NAME}-cert.pem@server:*'

.PHONY: destroy-test-cluster
destroy-test-cluster: ## Destroy test cluster
	@if k3d cluster list ${CLUSTER_NAME} >/dev/null 2>&1; then \
		if kubectl config current-context | grep '^k3d'; then \
			k3d cluster delete ${CLUSTER_NAME}; \
			if k3d cluster list ${CLUSTER_NAME} >/dev/null 2>&1; then \
				STR=" COUND NOT CLEAN UP THE CLUSTER ${CLUSTER_NAME}. PLEASE RESTART THE DOCKER DESKTOP AND TRY AGAIN! "; \
						CNT=`printf "$${STR}" | wc -c`; \
						printf "+"; \
				printf "%*s" $${CNT} | sed 's/ /-/g'; \
						printf "+\n"; \
						printf "|%s|\n" "$${STR}"; \
						printf "+"; \
				printf "%*s" $${CNT} | sed 's/ /-/g'; \
						printf "+\n"; \
			fi \
		fi \
	fi

.PHONY: kubeconfig-admin
kubeconfig-admin:
	@k3d kubeconfig get ${CLUSTER_NAME}

.PHONY: kubeconfig-oidc
kubeconfig-oidc: ## Generate kubeconfig with OIDC authentication
	@if ! [ -n "$${namespace}" ]; then \
		echo "❌ namespace is not set"; \
		exit 1; \
	fi
	@TARGET_NAMESPACE=${namespace} set -a && source .env && set +a && envsubst < manifests/kubeconfig.yaml

.PHONY: kubelogin-decoded-token
kubelogin-decoded-token:
	@kubectl oidc-login get-token \
		--oidc-issuer-url=https://keycloak.${DOMAIN_HOST}/realms/${KEYCLOAK__REALM_NAME} \
		--oidc-client-id=kubernetes \
		--insecure-skip-tls-verify -v=0 \
		| jq -r '.status.token | split(".")[1] | @base64d | fromjson'

.PHONY: kubelogout
kubelogout:
	@rm -rf ~/.kube/cache/oidc-login/*

.PHONY: kubernetes-oidc-project-roles
kubernetes-oidc-project-roles: ## Create Kubernetes OIDC project roles
	@if ! [ -n "$${namespace}" ]; then \
		echo "❌ namespace is not set"; \
		exit 1; \
	fi
	@TARGET_NAMESPACE=${namespace} set -a && source .env && set +a && envsubst < manifests/kubernetes-oidc-project-roles.yaml

.PHONY: kubernetes-oidc-project-rolebinding
kubernetes-oidc-project-rolebinding: ## Create Kubernetes OIDC project rolebinding
	@if ! [ -n "$${namespace}" ]; then \
		echo "❌ namespace is not set"; \
		exit 1; \
	fi
	@if ! [ -n "$${group}" ]; then \
		echo "❌ group is not set"; \
		exit 1; \
	fi
	@if ! [ -n "$${role}" ]; then \
		echo "❌ role is not set"; \
		exit 1; \
	fi
	@TARGET_NAMESPACE=${namespace} GROUP=${group} ROLE=${role} set -a && source .env && set +a && envsubst < manifests/kubernetes-oidc-project-rolebinding.yaml

.PHONY: auth-test
auth-test: ## Deploy auth-test app
	@helm upgrade --install auth-test helm/auth-test \
		--namespace auth \
		--create-namespace \
		--set virtualService.domain=${DOMAIN_HOST}
	@echo "✅ Auth test app installed!"

.PHONY: destroy-auth-test
destroy-auth-test: ## Destroy auth-test app
	@helm uninstall auth-test --namespace auth
	@echo "✅ Auth test app uninstalled!"

.PHONY: dns
dns: ## Setup dnsmasq for local development
	@echo "🚀 Setting up dnsmasq for local development..."
	@echo "🌐 Using domain: ${DOMAIN_HOST}"
	@if ! command -v dnsmasq >/dev/null 2>&1; then \
		echo "❌ dnsmasq not found. Installing..."; \
		brew install dnsmasq; \
	fi
	@TEMPLATE_CONF="$(shell pwd)/dnsmasq.conf.template"; \
	PROJECT_CONF="$(shell pwd)/dnsmasq.conf"; \
	MAIN_CONF="$$(brew --prefix)/etc/dnsmasq.conf"; \
	echo "📝 Template config: $$TEMPLATE_CONF"; \
	echo "📝 Generated config: $$PROJECT_CONF"; \
	echo "📝 Main config: $$MAIN_CONF"; \
	if [ ! -f "$$TEMPLATE_CONF" ]; then \
		echo "❌ Template dnsmasq.conf.template not found: $$TEMPLATE_CONF"; \
		exit 1; \
	fi; \
	echo "🔧 Generating dnsmasq.conf from template with DOMAIN_HOST=${DOMAIN_HOST}..."; \
	cp "$$TEMPLATE_CONF" "$$PROJECT_CONF"; \
	echo "" >> "$$PROJECT_CONF"; \
	echo "# Domain configuration (generated from DOMAIN_HOST)" >> "$$PROJECT_CONF"; \
	echo "address=/${DOMAIN_HOST}/127.0.0.1" >> "$$PROJECT_CONF"; \
	echo "🧹 Removing existing ai-platform entries..."; \
	sudo sed -i '' '/ai-platform\/dnsmasq.*\.conf/d' "$$MAIN_CONF" 2>/dev/null || true; \
	echo "➕ Adding generated config to main dnsmasq.conf..."; \
	echo "conf-file=$$PROJECT_CONF" | sudo tee -a "$$MAIN_CONF" >/dev/null; \
	echo "🧪 Testing configuration..."; \
	if sudo dnsmasq --test; then \
		echo "✅ Configuration syntax OK"; \
	else \
		echo "❌ Configuration error"; \
		exit 1; \
	fi; \
	echo "🔄 Restarting dnsmasq..."; \
	sudo brew services restart dnsmasq; \
	echo "🌐 Configuring system DNS..."; \
	sudo networksetup -setdnsservers "Wi-Fi" 127.0.0.1; \
	echo "🗑️  Flushing DNS cache..."; \
	sudo dscacheutil -flushcache; \
	sudo killall -HUP mDNSResponder; \
	sleep 2; \
	echo "🧪 Testing DNS resolution..."; \
	if nslookup ${DOMAIN_HOST} | grep -q "127.0.0.1"; then \
		echo "✅ ${DOMAIN_HOST} resolves to 127.0.0.1"; \
		echo ""; \
		echo "✅ DNS setup complete!"; \
		echo "📡 ${DOMAIN_HOST} domains now point to local cluster"; \
	else \
		echo "❌ DNS resolution test failed"; \
		echo "🔄 Rolling back DNS configuration..."; \
		$(MAKE) destroy-dns; \
		exit 1; \
	fi;

.PHONY: destroy-dns
destroy-dns: ## Cleanup dnsmasq configuration
	@echo "🧹 Cleaning up dnsmasq configuration..."
	@PROJECT_CONF="$(shell pwd)/dnsmasq.conf"; \
	MAIN_CONF="$$(brew --prefix)/etc/dnsmasq.conf"; \
	echo "🗑️  Removing ai-platform entries from $$MAIN_CONF..."; \
	sudo sed -i '' '/ai-platform\/dnsmasq.*\.conf/d' "$$MAIN_CONF" 2>/dev/null || true; \
	echo "🗑️  Removing generated config file..."; \
	rm -f "$$PROJECT_CONF"; \
	echo "🔄 Restarting dnsmasq..."; \
	sudo brew services restart dnsmasq; \
	echo "🌐 Restoring system DNS..."; \
	sudo networksetup -setdnsservers "Wi-Fi" 8.8.8.8 8.8.4.4; \
	echo "🗑️  Flushing DNS cache..."; \
	sudo dscacheutil -flushcache; \
	sudo killall -HUP mDNSResponder; \
	echo "✅ DNS cleanup complete!"

.PHONY: internal-dns
internal-dns: ## Setup internal DNS for local development
	@echo "🚀 Setting up internal DNS for local development..."
	@echo "🌐 Using domain: ${DOMAIN_HOST}"
	@echo "🔧 Generating internal DNS configuration..."
	@echo "📝 Creating CoreDNS configuration with template plugin..."
	@DOMAIN_HOST=${DOMAIN_HOST} ISTIO__NAMESPACE=${ISTIO__NAMESPACE} bash scripts/coredns-custom.sh
	@echo "✅ Internal DNS setup complete!"
# NOTE: kubectl rollout restart deployment coredns -n kube-system

.PHONY: destroy-internal-dns
destroy-internal-dns: ## Destroy internal DNS for local development
	@echo "🧹 Cleaning up internal DNS configuration..."
	@kubectl delete configmap coredns-custom -n kube-system
	@echo "✅ Internal DNS cleanup complete!"

.PHONY: test-internal-dns
test-internal-dns:
	@GITEA_POD_NAME=$$(kubectl get pods -n gitea -o jsonpath='{.items[0].metadata.name}'); \
	kubectl exec -n gitea $$GITEA_POD_NAME -- nslookup keycloak.${DOMAIN_HOST}

.PHONY: current-internal-dns
current-internal-dns:
	@kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}'

.PHONY: add-istio-repo
add-istio-repo: ## Add istio repo
	@helm repo add istio https://istio-release.storage.googleapis.com/charts
	@helm repo update

.PHONY: install-istio-base
install-istio-base: ## Install istio/base chart
	@if [ ! -f "helm/istio/base/Chart.yaml" ]; then \
		echo "📦 Downloading Istio base chart..."; \
		$(MAKE) add-istio-repo; \
		mkdir -p helm/istio; \
		helm pull istio/base --untar --untardir helm/istio; \
		echo "✅ Istio base chart downloaded to helm/istio/base/"; \
	else \
		echo "✅ Istio base chart already exists (helm/istio/base/Chart.yaml found)"; \
	fi

.PHONY: install-istio-istiod
install-istio-istiod: ## Install istio/istiod chart
	@if [ ! -f "helm/istio/istiod/Chart.yaml" ]; then \
		echo "📦 Downloading Istio istiod chart..."; \
		$(MAKE) add-istio-repo; \
		mkdir -p helm/istio; \
		helm pull istio/istiod --untar --untardir helm/istio; \
		echo "✅ Istio istiod chart downloaded to helm/istio/istiod/"; \
	else \
		echo "✅ Istio istiod chart already exists (helm/istio/istiod/Chart.yaml found)"; \
	fi

.PHONY: install-istio-gateway
install-istio-gateway: ## Install istio/gateway chart
	@if [ ! -f "helm/istio/gateway/Chart.yaml" ]; then \
		echo "📦 Downloading Istio gateway chart..."; \
		$(MAKE) add-istio-repo; \
		mkdir -p helm/istio; \
		helm pull istio/gateway --untar --untardir helm/istio; \
		echo "✅ Istio gateway chart downloaded to helm/istio/gateway/"; \
	else \
		echo "✅ Istio gateway chart already exists (helm/istio/gateway/Chart.yaml found)"; \
	fi

.PHONY: install-istio
install-istio: install-istio-base install-istio-istiod install-istio-gateway ## Install istio charts

.PHONY: ai-platform-gateway
ai-platform-gateway: deprecated-tls ## Deploy AI platform gateway chart
	@helm upgrade --install ai-platform-gateway helm/istio/ai-platform-gateway \
		--namespace ${ISTIO__NAMESPACE} --create-namespace \
		--set host=${DOMAIN_HOST} \
		--set tls.enabled=true \
		--set tls.credentialName=${CLUSTER_NAME}-tls

.PHONY: istio
istio: install-istio ## Deploy istio base and istiod charts
	@helm upgrade --install istio-base helm/istio/base -n ${ISTIO__NAMESPACE} --create-namespace
	@helm upgrade --install istio-istiod helm/istio/istiod -n ${ISTIO__NAMESPACE} --create-namespace
	@helm upgrade --install istio-gateway helm/istio/gateway -n ${ISTIO__NAMESPACE} --create-namespace
	@$(MAKE) ai-platform-gateway
	@$(MAKE) internal-dns

.PHONY: virtualservice
virtualservice: ## Deploy virtual service
	@if [ -z "${name}" ]; then \
		echo "❌ Error: name is not set"; \
		echo "💡 Usage: make virtualservice name=service-name port=8080 namespace=default service_name=my-service subdomain=test"; \
		exit 1; \
	fi
	@if [ -z "${port}" ]; then \
		echo "❌ Error: port is not set"; \
		echo "💡 Usage: make virtualservice name=service-name port=8080 namespace=default service_name=my-service subdomain=test"; \
		exit 1; \
	fi
	@if [ -z "${namespace}" ]; then \
		echo "❌ Error: namespace is not set"; \
		echo "💡 Usage: make virtualservice name=service-name port=8080 namespace=default service_name=my-service subdomain=test"; \
		exit 1; \
	fi
	@if [ -z "${service_name}" ]; then \
		echo "❌ Error: service_name is not set"; \
		echo "💡 Usage: make virtualservice name=service-name port=8080 namespace=default service_name=my-service subdomain=test"; \
		exit 1; \
	fi
	@if [ -z "${subdomain}" ]; then \
		echo "❌ Error: subdomain is not set"; \
		echo "💡 Usage: make virtualservice name=service-name port=8080 namespace=default service_name=my-service subdomain=test"; \
		exit 1; \
	fi
	@NAME=${name} PORT=${port} NAMESPACE=${namespace} SERVICE_NAME=${service_name} SUBDOMAIN=${subdomain} set -a && source .env && set +a && envsubst < manifests/virtualservice.yaml | kubectl apply -f -
	@echo "✅ Virtual service deployed!"

.PHONY: destroy-virtualservice
destroy-virtualservice: ## Destroy virtual service
	@kubectl delete virtualservice ${name} -n ${namespace}
	@echo "✅ Virtual service destroyed!"

.PHONY: add-cnpg-repo
add-cnpg-repo: ## Add cnpg repo
	@helm repo add cnpg https://cloudnative-pg.github.io/charts
	@helm repo update

.PHONY: install-cnpg-cloudnative-pg
install-cnpg-cloudnative-pg: ## Install cnpg/cloudnative-pg chart
	@if [ ! -f "helm/cnpg/cloudnative-pg/Chart.yaml" ]; then \
		echo "📦 Downloading cnpg chart..."; \
		$(MAKE) add-cnpg-repo; \
		mkdir -p helm/cnpg; \
		helm pull cnpg/cloudnative-pg --untar --untardir helm/cnpg; \
		echo "✅ cnpg/cloudnative-pg chart downloaded to helm/cnpg/"; \
	else \
		echo "✅ cnpg/cloudnative-pg chart already exists (helm/cnpg/cloudnative-pg/Chart.yaml found)"; \
	fi

.PHONY: install-cnpg-cluster
install-cnpg-cluster: ## Install cnpg/cluster chart
	@if [ ! -f "helm/cnpg/cluster/Chart.yaml" ]; then \
		echo "📦 Downloading cnpg/cluster chart..."; \
		$(MAKE) add-cnpg-repo; \
		mkdir -p helm/cnpg; \
		helm pull cnpg/cluster --untar --untardir helm/cnpg; \
		echo "✅ cnpg/cluster chart downloaded to helm/cnpg/"; \
	else \
		echo "✅ cnpg/cluster chart already exists (helm/cnpg/cluster/Chart.yaml found)"; \
	fi

.PHONY: install-cnpg
install-cnpg: install-cnpg-cloudnative-pg install-cnpg-cluster ## Install cnpg charts

#		--set cluster.initdb.postInitSQL[0]="CREATE DATABASE ${KEYCLOAK__DATABASE_NAME};" \
#		--set cluster.initdb.postInitSQL[1]="CREATE DATABASE ${GITEA__DATABASE_NAME};" \
#		--set cluster.initdb.postInitSQL[2]="GRANT ALL PRIVILEGES ON SCHEMA ${CNPG__DATABASE_SCHEMA} TO ${CNPG__ADMIN_USERNAME};" \
#		--set cluster.initdb.postInitSQL[3]="GRANT ALL PRIVILEGES ON DATABASE ${KEYCLOAK__DATABASE_NAME} TO ${CNPG__ADMIN_USERNAME};" \
#		--set cluster.initdb.postInitSQL[4]="GRANT ALL PRIVILEGES ON DATABASE ${GITEA__DATABASE_NAME} TO ${CNPG__ADMIN_USERNAME};" \

.PHONY: cnpg
cnpg: install-cnpg ## Install cnpg charts
	@helm upgrade --install cnpg-cloudnative-pg helm/cnpg/cloudnative-pg -n ${CNPG__OPERATOR_NAMESPACE} --create-namespace --wait
#	--set config.clusterWide=false \
#	--set config.data.WATCH_NAMESPACE=${CNPG__DATABASE_NAMESPACE}
# TODO: enable backups
# TODO: enable recovery
	@echo "🔐 Creating admin user secret..."
	@kubectl create namespace ${CNPG__DATABASE_NAMESPACE} || true
	@kubectl create secret generic ${CNPG__ADMIN_SECRET} \
		--from-literal=username=${CNPG__ADMIN_USERNAME} \
		--from-literal=password=${CNPG__ADMIN_PASSWORD} \
		--type=kubernetes.io/basic-auth \
		-n ${CNPG__DATABASE_NAMESPACE} \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "✅ Admin user secret created!"
	@helm upgrade --install cnpg-cluster helm/cnpg/cluster \
		-n ${CNPG__DATABASE_NAMESPACE} --create-namespace \
		--set cluster.initdb.database=${CNPG__DATABASE_NAME} \
		--set cluster.initdb.owner=${CNPG__ADMIN_USERNAME} \
		--set cluster.initdb.secret.name=${CNPG__ADMIN_SECRET} \
		--set cluster.enableSuperuserAccess=true \
		--set cluster.initdb.postInitSQL[0]="ALTER USER ${CNPG__ADMIN_USERNAME} WITH SUPERUSER;" \
		--set cluster.initdb.postInitSQL[1]="CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" \
		--set cluster.initdb.postInitSQL[2]="CREATE EXTENSION IF NOT EXISTS pgcrypto;" \
		--set cluster.postgresql.shared_preload_libraries[0]=pg_stat_statements \
		--set poolers[0].name=rw \
		--set poolers[0].type=rw \
		--set poolers[0].poolMode=session \
		--set poolers[0].instances=${CNPG__POOLER_RW_REPLICAS} \
		--set-string poolers[0].parameters.max_client_conn=100 \
		--set-string poolers[0].parameters.default_pool_size=10 \
		--set poolers[0].monitoring.enabled=false \
		--set poolers[0].monitoring.podMonitor.enabled=true \
		--set poolers[1].name=ro \
		--set poolers[1].type=ro \
		--set poolers[1].poolMode=transaction \
		--set poolers[1].instances=${CNPG__POOLER_RO_REPLICAS} \
		--set-string poolers[1].parameters.max_client_conn=200 \
		--set-string poolers[1].parameters.default_pool_size=20 \
		--set poolers[1].monitoring.enabled=false \
		--set poolers[1].monitoring.podMonitor.enabled=true
# TODO: enable monitoring
# TODO: enable logging

.PHONY: destroy-cnpg
destroy-cnpg: ## Destroy cnpg cluster and operator
	@echo "🗑️  Removing CNPG cluster..."
	@helm uninstall cnpg-cluster -n ${CNPG__DATABASE_NAMESPACE} 2>/dev/null || echo "cnpg-cluster not found"
	@echo "🗑️  Removing admin secret..."
	@kubectl delete secret ${CNPG__ADMIN_SECRET} -n ${CNPG__DATABASE_NAMESPACE} 2>/dev/null || echo "platform-admin-secret not found"
	@echo "🗑️  Removing CNPG operator..."
	@helm uninstall cnpg-cloudnative-pg -n ${CNPG__OPERATOR_NAMESPACE} 2>/dev/null || echo "cnpg-cloudnative-pg not found"
	@echo "✅ CNPG cleanup complete!"

.PHONY: database
database: ## Create database
	@if [ -z "${name}" ]; then \
		echo "❌ Error: name is not set or empty"; \
		echo "💡 Usage: make database-create name=your_database_name [owner=owner_name]"; \
		exit 1; \
	fi
	@echo "🔐 Creating database: ${name}..."
	@if [ -n "${owner}" ]; then \
		echo "👤 Database owner: ${owner}"; \
	fi
	@CNPG_POD_NAME=$$(kubectl get endpoints ${CNPG__RW_SERVICE} -n ${CNPG__DATABASE_NAMESPACE} -o jsonpath='{.subsets[0].addresses[0].targetRef.name}' 2>/dev/null); \
	if [ -z "$$CNPG_POD_NAME" ]; then \
		echo "❌ Error: No pod found for service ${CNPG__RW_SERVICE} in namespace ${CNPG__DATABASE_NAMESPACE}"; \
		exit 1; \
	fi; \
	echo "🔍 Using pod: $$CNPG_POD_NAME (from service ${CNPG__RW_SERVICE})"; \
	if [ -n "${owner}" ]; then \
		kubectl exec -n ${CNPG__DATABASE_NAMESPACE} $$CNPG_POD_NAME -c postgres -- psql -c "CREATE DATABASE ${name} OWNER ${owner};" 2>/dev/null && echo "✅ Database ${name} created with owner ${owner}" || echo "⚠️  Database ${name} already exists or owner ${owner} not found"; \
	else \
		kubectl exec -n ${CNPG__DATABASE_NAMESPACE} $$CNPG_POD_NAME -c postgres -- psql -c "CREATE DATABASE ${name};" 2>/dev/null && echo "✅ Database ${name} created" || echo "⚠️  Database ${name} already exists"; \
	fi

.PHONY: destroy-database
destroy-database: ## Destroy database
	@if [ -z "${name}" ]; then \
		echo "❌ Error: name is not set or empty"; \
		echo "💡 Usage: make destroy-database name=your_database_name"; \
		exit 1; \
	fi
	@echo "🗑️  Removing database: ${name}..."
	@CNPG_POD_NAME=$$(kubectl get endpoints ${CNPG__RW_SERVICE} -n ${CNPG__DATABASE_NAMESPACE} -o jsonpath='{.subsets[0].addresses[0].targetRef.name}' 2>/dev/null); \
	if [ -z "$$CNPG_POD_NAME" ]; then \
		echo "❌ Error: No pod found for service ${CNPG__RW_SERVICE} in namespace ${CNPG__DATABASE_NAMESPACE}"; \
		exit 1; \
	fi; \
	echo "🔍 Using pod: $$CNPG_POD_NAME (from service ${CNPG__RW_SERVICE})"; \
	kubectl exec -n ${CNPG__DATABASE_NAMESPACE} $$CNPG_POD_NAME -c postgres -- psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${name}' AND pid<>pg_backend_pid();" 2>/dev/null && echo "✅ Closed connections to ${name}" || echo "⚠️  No connections to ${name} found"; \
	kubectl exec -n ${CNPG__DATABASE_NAMESPACE} $$CNPG_POD_NAME -c postgres -- psql -c "DROP DATABASE IF EXISTS ${name};" 2>/dev/null && echo "✅ Database ${name} destroyed" || echo "⚠️  Database ${name} not found";

.PHONY: add-keycloak-repo
add-keycloak-repo: ## Add keycloak repo
	@helm repo add bitnami https://charts.bitnami.com/bitnami
	@helm repo update

.PHONY: install-keycloak
install-keycloak:
	@if [ ! -f "helm/keycloak/Chart.yaml" ]; then \
		echo "📦 Downloading bitnami/keycloak chart..."; \
		$(MAKE) add-keycloak-repo; \
		mkdir -p helm; \
		helm pull bitnami/keycloak --untar --untardir helm; \
		echo "✅ bitnami/keycloak chart downloaded to helm/keycloak/"; \
	else \
		echo "✅ bitnami/keycloak chart already exists (helm/keycloak/Chart.yaml found)"; \
	fi

.PHONY: keycloak
keycloak: install-keycloak ## Install keycloak chart
	@$(MAKE) database name=${KEYCLOAK__DATABASE_NAME}
	@helm upgrade --install keycloak helm/keycloak \
		-n ${KEYCLOAK__NAMESPACE} --create-namespace \
		--set image.repository=bitnamilegacy/keycloak \
		--set replicaCount=${KEYCLOAK__REPLICAS} \
		--set postgresql.enabled=false \
		--set service.ports.http=${KEYCLOAK__HTTP_PORT} \
		--set service.ports.https=${KEYCLOAK__HTTPS_PORT} \
		--set externalDatabase.host=${KEYCLOAK__DATABASE_HOST} \
		--set externalDatabase.port=${KEYCLOAK__DATABASE_PORT} \
		--set externalDatabase.database=${KEYCLOAK__DATABASE_NAME} \
		--set externalDatabase.user=${KEYCLOAK__DATABASE_USERNAME} \
		--set externalDatabase.password=${KEYCLOAK__DATABASE_PASSWORD} \
		--set auth.adminUser=${KEYCLOAK__ADMIN_USERNAME} \
		--set auth.adminPassword=${KEYCLOAK__ADMIN_PASSWORD} \
		--set extraEnvVars[0].name=KC_HOSTNAME \
		--set extraEnvVars[0].value=keycloak.${DOMAIN_HOST} \
		--set extraEnvVars[1].name=KC_PROXY_HEADERS \
		--set extraEnvVars[1].value=xforwarded
	@$(MAKE) virtualservice name=keycloak port=${KEYCLOAK__HTTP_PORT} namespace=${KEYCLOAK__NAMESPACE} service_name=${KEYCLOAK__SERVICE_NAME} subdomain=keycloak
	@echo "✅ Keycloak installed!"
# 		--set extraEnvVars[1].name=KC_HOSTNAME_STRICT
# 		--set-string extraEnvVars[1].value=false
#
#  - name: KC_HOSTNAME_STRICT
#    value: "true"
#  - name: KC_HOSTNAME_STRICT_HTTPS
#    value: "true"
#  - name: KC_PROXY
#    value: "edge"
#  - name: KC_HTTP_ENABLED
#    value: "true"

.PHONY: destroy-keycloak
destroy-keycloak: ## Destroy keycloak
	@helm uninstall keycloak -n ${KEYCLOAK__NAMESPACE}
	@$(MAKE) destroy-virtualservice name=keycloak namespace=${KEYCLOAK__NAMESPACE}
	@echo "✅ Keycloak uninstalled!"

.PHONY: add-gitea-repo
add-gitea-repo: ## Add gitea repo
	@helm repo add gitea-charts https://dl.gitea.com/charts/
	@helm repo update

.PHONY: install-gitea
install-gitea: ## Install gitea chart
	@if [ ! -f "helm/gitea/Chart.yaml" ]; then \
		echo "📦 Downloading gitea-charts/gitea chart..."; \
		$(MAKE) add-gitea-repo; \
		mkdir -p helm; \
		helm pull gitea-charts/gitea --untar --untardir helm; \
		echo "✅ gitea-charts/gitea chart downloaded to helm/gitea/"; \
	else \
		echo "✅ gitea-charts/gitea chart already exists (helm/gitea/Chart.yaml found)"; \
	fi

# NOTE: autoDiscoverUrl은 내부 클러스터 주소 사용해야 함
.PHONY: gitea
gitea: install-gitea ## Install gitea chart
	-@$(MAKE) ca namespace=${GITEA__NAMESPACE}
	@$(MAKE) database name=${GITEA__DATABASE_NAME}
	-@REALM_NAME=${KEYCLOAK__REALM_NAME} bash scripts/gitea.sh
	@echo "🔑 Getting Gitea client secret from Keycloak..."
	@GITEA__CLIENT_SECRET=$$(bash scripts/keycloak.sh get-client-secret gitea); \
	if [ $$? -ne 0 ] || [ -z "$$GITEA__CLIENT_SECRET" ]; then \
		echo "❌ Failed to get Gitea client secret from Keycloak"; \
		exit 1; \
	fi; \
	echo "✅ Gitea client secret retrieved successfully"; \
	echo "🚀 Installing Gitea with OAuth configuration..."; \
	helm upgrade --install gitea helm/gitea \
		-n ${GITEA__NAMESPACE} --create-namespace \
		--set gitea.admin.username=${GITEA__ADMIN_USERNAME} \
		--set gitea.admin.password=${GITEA__ADMIN_PASSWORD} \
		--set gitea.admin.email=${GITEA__ADMIN_EMAIL} \
		--set postgresql-ha.enabled=false \
		--set postgresql.enabled=false \
		--set valkey-cluster.enabled=false \
		--set valkey.enabled=false \
		--set service.http.port=${GITEA__HTTP_PORT} \
		--set gitea.config.database.DB_TYPE=${GITEA__DATABASE_TYPE} \
		--set gitea.config.database.HOST=${GITEA__DATABASE_HOST} \
		--set gitea.config.database.PORT=${GITEA__DATABASE_PORT} \
		--set gitea.config.database.NAME=${GITEA__DATABASE_NAME} \
		--set gitea.config.database.USER=${GITEA__DATABASE_USERNAME} \
		--set gitea.config.database.PASSWD=${GITEA__DATABASE_PASSWORD} \
		--set gitea.oauth[0].name=keycloak \
		--set gitea.oauth[0].provider=openidConnect \
		--set gitea.oauth[0].key=gitea \
		--set gitea.oauth[0].secret=$$GITEA__CLIENT_SECRET \
		--set gitea.oauth[0].autoDiscoverUrl=https://keycloak.${DOMAIN_HOST}/realms/${KEYCLOAK__REALM_NAME}/.well-known/openid-configuration \
		--set gitea.oauth[0].scopes="openid profile email" \
		--set gitea.config.server.ROOT_URL=https://gitea.${DOMAIN_HOST}/ \
		--set deployment.env[0].name=SSL_CERT_FILE \
		--set deployment.env[0].value=/etc/ssl/certs/${CLUSTER_NAME}-ca.crt \
		--set deployment.env[1].name=GITEA__service__DISABLE_REGISTRATION \
		--set-string deployment.env[1].value=true \
		--set deployment.env[2].name=GITEA__service__ENABLE_PASSWORD_SIGNIN_FORM \
		--set-string deployment.env[2].value=false \
		--set deployment.env[3].name=GITEA__oauth2_client__ENABLE_AUTO_REGISTRATION \
		--set-string deployment.env[3].value=true \
		--set deployment.env[4].name=GITEA__oauth2_client__USERNAME \
		--set-string deployment.env[4].value=preferred_username \
		--set deployment.env[5].name=GITEA__oauth2_client__ACCOUNT_LINKING \
		--set-string deployment.env[5].value=auto \
		--set extraVolumes[0].name=${CLUSTER_NAME}-ca \
		--set extraVolumes[0].secret.secretName=${CLUSTER_NAME}-ca \
		--set extraVolumes[0].secret.items[0].key=ca.crt \
		--set extraVolumes[0].secret.items[0].path=${CLUSTER_NAME}-ca.crt \
		--set extraVolumeMounts[0].name=${CLUSTER_NAME}-ca \
		--set extraVolumeMounts[0].mountPath=/etc/ssl/certs/${CLUSTER_NAME}-ca.crt \
		--set extraVolumeMounts[0].subPath=${CLUSTER_NAME}-ca.crt \
		--set extraVolumeMounts[0].readOnly=true
	@$(MAKE) virtualservice name=gitea port=${GITEA__HTTP_PORT} namespace=${GITEA__NAMESPACE} service_name=${GITEA__SERVICE_NAME} subdomain=gitea
	@echo "✅ Gitea installed!"

.PHONY: destroy-gitea
destroy-gitea: ## Destroy gitea chart
	@helm uninstall gitea -n ${GITEA__NAMESPACE}
	@$(MAKE) destroy-virtualservice name=gitea namespace=${GITEA__NAMESPACE}
	@$(MAKE) destroy-database name=${GITEA__DATABASE_NAME}
	@REALM_NAME=${KEYCLOAK__REALM_NAME} bash scripts/keycloak.sh remove-client gitea
	@echo "✅ Gitea uninstalled!"

.PHONY: add-airflow-repo
add-airflow-repo: ## Add airflow repo
	@helm repo add apache-airflow https://airflow.apache.org
	@helm repo update

.PHONY: install-airflow
install-airflow: ## Install airflow chart
	@if [ ! -f "helm/airflow/Chart.yaml" ]; then \
		echo "📦 Downloading apache-airflow/airflow chart version ${AIRFLOW__CHART_VERSION}..."; \
		$(MAKE) add-airflow-repo; \
		mkdir -p helm; \
		helm pull apache-airflow/airflow --version ${AIRFLOW__CHART_VERSION} --untar --untardir helm; \
		echo "✅ apache-airflow/airflow chart version ${AIRFLOW__CHART_VERSION} downloaded to helm/airflow/"; \
	fi

.PHONY: airflow
airflow: install-airflow ## Install airflow chart
# --set brokerdata.brokerUrl=redis://redis-master:6379/0
	@$(MAKE) database name=${AIRFLOW__DATABASE_NAME}
	-@kubectl create namespace ${AIRFLOW__NAMESPACE} || true
	-@kubectl create namespace ${OPENMETADATA__NAMESPACE} || true
	-@kubectl create secret generic ${AIRFLOW__ADMIN_SECRET} \
		--from-literal=username=${AIRFLOW__ADMIN_USERNAME} \
		--from-literal=${AIRFLOW__ADMIN_SECRET_KEY}=${AIRFLOW__ADMIN_PASSWORD} \
		--type=kubernetes.io/basic-auth \
		-n ${OPENMETADATA__NAMESPACE}
	@helm upgrade --install airflow helm/airflow \
		-n ${AIRFLOW__NAMESPACE} --create-namespace \
		--set webserver.enabled=true \
		--set webserver.defaultUser.enabled=true \
		--set webserver.defaultUser.username=${AIRFLOW__ADMIN_USERNAME} \
		--set webserver.defaultUser.password=${AIRFLOW__ADMIN_PASSWORD} \
		--set webserver.defaultUser.email=${AIRFLOW__ADMIN_EMAIL} \
		--set webserver.defaultUser.firstName=${AIRFLOW__ADMIN_FIRST_NAME} \
		--set webserver.defaultUser.lastName=${AIRFLOW__ADMIN_LAST_NAME} \
		--set webserver.defaultUser.role=Admin \
		--set postgresql.enabled=false \
		--set executor=${AIRFLOW__EXECUTOR} \
		--set data.metadataConnection.host=${AIRFLOW__DATABASE_HOST} \
		--set data.metadataConnection.port=${AIRFLOW__DATABASE_PORT} \
		--set data.metadataConnection.db=${AIRFLOW__DATABASE_NAME} \
		--set data.metadataConnection.protocol=${AIRFLOW__DATABASE_PROTOCOL} \
		--set data.metadataConnection.user=${AIRFLOW__DATABASE_USERNAME} \
		--set data.metadataConnection.pass=${AIRFLOW__DATABASE_PASSWORD} \
		--set data.metadataConnection.sslmode=${AIRFLOW__DATABASE_SSL_MODE} \
		--set ports.airflowUI=${AIRFLOW__HTTP_PORT} \
		--set ports.apiServer=${AIRFLOW__HTTP_PORT} \
		--set workers.replicas=${AIRFLOW__WORKERS_REPLICAS} \
		--set scheduler.replicas=${AIRFLOW__SCHEDULER_REPLICAS} \
		--set webserver.replicas=${AIRFLOW__WEBSERVER_REPLICAS} \
		--set triggerer.replicas=${AIRFLOW__TRIGGERER_REPLICAS} \
		--set images.airflow.repository=${AIRFLOW__IMAGE_REPOSITORY} \
		--set images.airflow.tag=${AIRFLOW__IMAGE_TAG} \
		--set dags.persistence.enabled=true \
		--set dags.persistence.storageClassName=${RWX_STORAGE_CLASS_NAME} \
		--set dags.persistence.accessMode=ReadWriteMany \
		--set dags.persistence.size=1Gi \
		--set webserver.extraVolumes[0].name=dags \
		--set webserver.extraVolumes[0].persistentVolumeClaim.claimName=airflow-dags \
		--set webserver.extraVolumeMounts[0].name=dags \
		--set webserver.extraVolumeMounts[0].mountPath=/opt/airflow/dags \
		--set webserver.extraVolumeMounts[0].readOnly=false \
		-f manifests/airflow-config.yaml
	@$(MAKE) virtualservice name=airflow port=${AIRFLOW__HTTP_PORT} namespace=${AIRFLOW__NAMESPACE} service_name=${AIRFLOW__SERVICE_NAME} subdomain=airflow
	@echo "✅ Airflow installed!"

.PHONY: destroy-airflow
destroy-airflow: ## Destroy airflow chart
	@helm uninstall airflow -n ${AIRFLOW__NAMESPACE} --wait
	-@$(MAKE) destroy-virtualservice name=airflow namespace=${AIRFLOW__NAMESPACE}
	-@kubectl delete pvc -l release=airflow -n ${AIRFLOW__NAMESPACE}
	-@kubectl delete secret ${AIRFLOW__ADMIN_SECRET} -n ${OPENMETADATA__NAMESPACE}
	-@$(MAKE) destroy-database name=${AIRFLOW__DATABASE_NAME}
	@echo "✅ Airflow uninstalled!"

.PHONY: add-openmetadata-repo
add-openmetadata-repo: ## Add openmetadata repo
	@helm repo add open-metadata https://helm.open-metadata.org/
	@helm repo update

.PHONY: install-openmetadata
install-openmetadata: ## Install openmetadata chart
	@if [ ! -f "helm/openmetadata/Chart.yaml" ]; then \
		echo "📦 Downloading open-metadata/openmetadata chart..."; \
		$(MAKE) add-openmetadata-repo; \
		mkdir -p helm; \
		helm pull open-metadata/openmetadata --untar --untardir helm; \
		echo "✅ open-metadata/openmetadata chart downloaded to helm/openmetadata/"; \
	else \
		echo "✅ open-metadata/openmetadata chart already exists (helm/openmetadata/Chart.yaml found)"; \
	fi

.PHONY: openmetadata
openmetadata: install-openmetadata ## Install openmetadata chart
	-@kubectl create namespace ${OPENMETADATA__NAMESPACE} || true
	@$(MAKE) database name=${OPENMETADATA__DATABASE_NAME}
	-@kubectl create secret generic ${OPENMETADATA__ADMIN_SECRET} \
		--from-literal=username=${OPENMETADATA__DATABASE_USERNAME} \
		--from-literal=${OPENMETADATA__ADMIN_SECRET_KEY}=${OPENMETADATA__DATABASE_PASSWORD} \
		--type=kubernetes.io/basic-auth \
		-n ${OPENMETADATA__NAMESPACE}
	@helm upgrade --install openmetadata helm/openmetadata \
		-n ${OPENMETADATA__NAMESPACE} --create-namespace \
		--set openmetadata.config.authentication.enabled=true \
		--set openmetadata.config.openmetadata.port=${OPENMETADATA__HTTP_PORT} \
		--set service.port=${OPENMETADATA__HTTP_PORT} \
		--set openmetadata.config.database.host=${OPENMETADATA__DATABASE_HOST} \
		--set openmetadata.config.database.port=${OPENMETADATA__DATABASE_PORT} \
		--set openmetadata.config.database.driverClass=${OPENMETADATA__DATABASE_DRIVER_CLASS} \
		--set openmetadata.config.database.dbScheme=${OPENMETADATA__DATABASE_PROTOCOL} \
		--set openmetadata.config.database.databaseName=${OPENMETADATA__DATABASE_NAME} \
		--set openmetadata.config.database.auth.username=${OPENMETADATA__DATABASE_USERNAME} \
		--set openmetadata.config.database.auth.password.secretRef=${OPENMETADATA__ADMIN_SECRET}\
		--set openmetadata.config.database.auth.password.secretKey=${OPENMETADATA__ADMIN_SECRET_KEY} \
		--set openmetadata.config.database.dbParams="sslmode=disable" \
		--set openmetadata.config.authorizer.principalDomain=${DOMAIN_HOST} \
		--set openmetadata.config.authorizer.enforcePrincipalDomain=false \
		--set openmetadata.config.authorizer.useRolesFromProvider=true \
		--set openmetadata.config.jwtTokenConfiguration.jwtissuer=${DOMAIN_HOST} \
		--set openmetadata.config.authentication.enabled=true \
		--set openmetadata.config.authentication.clientType=public \
		--set openmetadata.config.authentication.provider=custom-oidc \
		--set openmetadata.config.authentication.publicKeys[0]=http://openmetadata.${OPENMETADATA__NAMESPACE}.svc.cluster.local:${OPENMETADATA__HTTP_PORT}/api/v1/system/config/jwks \
		--set openmetadata.config.authentication.publicKeys[1]=http://keycloak.${KEYCLOAK__NAMESPACE}.svc.cluster.local:${KEYCLOAK__HTTP_PORT}/realms/${KEYCLOAK__REALM_NAME}/protocol/openid-connect/certs \
		--set openmetadata.config.authentication.authority=https://keycloak.${DOMAIN_HOST}/realms/${KEYCLOAK__REALM_NAME} \
		--set openmetadata.config.authentication.clientId=${OPENMETADATA__OIDC_CLIENT_ID} \
		--set openmetadata.config.authentication.callbackUrl=https://openmetadata.${DOMAIN_HOST}/callback \
		--set openmetadata.config.elasticsearch.enabled=true \
		--set openmetadata.config.elasticsearch.host=opensearch-cluster-master.${OPENSEARCH__NAMESPACE}.svc.cluster.local \
		--set openmetadata.config.elasticsearch.port=${OPENSEARCH__HTTP_PORT} \
		--set openmetadata.config.elasticsearch.scheme=http \
		--set openmetadata.config.elasticsearch.auth.enabled=true \
		--set openmetadata.config.elasticsearch.auth.username=${OPENSEARCH__ADMIN_USERNAME} \
		--set openmetadata.config.elasticsearch.auth.password.secretRef=${OPENSEARCH__ADMIN_SECRET} \
		--set openmetadata.config.elasticsearch.auth.password.secretKey=${OPENSEARCH__ADMIN_SECRET_KEY} \
		--set openmetadata.config.elasticsearch.searchType=opensearch \
		--set openmetadata.config.pipelineServiceClientConfig.apiEndpoint=http://airflow-webserver.${AIRFLOW__NAMESPACE}.svc.cluster.local:${AIRFLOW__HTTP_PORT} \
		--set openmetadata.config.pipelineServiceClientConfig.metadataApiEndpoint=http://openmetadata.${OPENMETADATA__NAMESPACE}.svc.cluster.local:${OPENMETADATA__HTTP_PORT}/api \
		--set openmetadata.config.pipelineServiceClientConfig.verifySsl=no-ssl \
		--set openmetadata.config.pipelineServiceClientConfig.hostIp= \
		--set openmetadata.config.pipelineServiceClientConfig.ingestionIpInfoEnabled=false \
		--set openmetadata.config.pipelineServiceClientConfig.healthCheckInterval=300 \
		--set openmetadata.config.pipelineServiceClientConfig.sslCertificatePath=/no/path \
		--set openmetadata.config.pipelineServiceClientConfig.auth.enabled=true \
		--set openmetadata.config.pipelineServiceClientConfig.auth.username=${AIRFLOW__ADMIN_USERNAME} \
		--set openmetadata.config.pipelineServiceClientConfig.auth.password.secretRef=${AIRFLOW__ADMIN_SECRET} \
		--set openmetadata.config.pipelineServiceClientConfig.auth.password.secretKey=${AIRFLOW__ADMIN_SECRET_KEY}
	@$(MAKE) virtualservice name=openmetadata port=${OPENMETADATA__HTTP_PORT} namespace=${OPENMETADATA__NAMESPACE} service_name=${OPENMETADATA__SERVICE_NAME} subdomain=openmetadata
	@echo "✅ Openmetadata installed!"

.PHONY: destroy-openmetadata
destroy-openmetadata: ## Destroy openmetadata chart
	@helm uninstall openmetadata -n ${OPENMETADATA__NAMESPACE} --wait
	-@$(MAKE) destroy-virtualservice name=openmetadata namespace=${OPENMETADATA__NAMESPACE}
	@$(MAKE) destroy-database name=${OPENMETADATA__DATABASE_NAME}
	@kubectl delete secret ${OPENMETADATA__ADMIN_SECRET} -n ${OPENMETADATA__NAMESPACE}
	@echo "✅ Openmetadata uninstalled!"

.PHONY: add-opensearch-repo
add-opensearch-repo: ## Add opensearch repo
	@helm repo add opensearch https://opensearch-project.github.io/helm-charts/
	@helm repo update

.PHONY: install-opensearch
install-opensearch: ## Install opensearch chart
	@if [ ! -f "helm/opensearch/Chart.yaml" ]; then \
		echo "📦 Downloading opensearch/opensearch chart..."; \
		$(MAKE) add-opensearch-repo; \
		mkdir -p helm; \
		helm pull opensearch/opensearch --untar --untardir helm; \
		echo "✅ opensearch/opensearch chart downloaded to helm/opensearch/"; \
	else \
		echo "✅ opensearch/opensearch chart already exists (helm/opensearch/Chart.yaml found)"; \
	fi

.PHONY: opensearch
opensearch: install-opensearch ## Install opensearch chart
	-@kubectl create namespace ${OPENSEARCH__NAMESPACE} || true
	-@kubectl create namespace ${OPENMETADATA__NAMESPACE} || true
	-@kubectl create secret generic ${OPENSEARCH__ADMIN_SECRET} \
		--from-literal=username=${OPENSEARCH__ADMIN_USERNAME} \
		--from-literal=${OPENSEARCH__ADMIN_SECRET_KEY}=${OPENSEARCH__ADMIN_PASSWORD} \
		--type=kubernetes.io/basic-auth \
		-n ${OPENMETADATA__NAMESPACE}
	@helm upgrade --install opensearch helm/opensearch \
		-n ${OPENSEARCH__NAMESPACE} --create-namespace \
		--set extraEnvs[0].name=OPENSEARCH_INITIAL_ADMIN_PASSWORD \
		--set extraEnvs[0].value=${OPENSEARCH__ADMIN_PASSWORD} \
		--set extraEnvs[1].name=plugins.security.ssl.http.enabled \
		--set-string extraEnvs[1].value=false \
		--set replicas=${OPENSEARCH__REPLICAS}
	@$(MAKE) virtualservice name=opensearch port=${OPENSEARCH__HTTP_PORT} namespace=${OPENSEARCH__NAMESPACE} service_name=${OPENSEARCH__SERVICE_NAME} subdomain=opensearch
	@echo "✅ Opensearch installed!"

# Opensearch HTTP 연결 관련 issue 참고
# https://github.com/opensearch-project/helm-charts/issues/610#issuecomment-2564864930

.PHONY: destroy-opensearch
destroy-opensearch: ## Destroy opensearch chart
	-@kubectl delete secret ${OPENSEARCH__ADMIN_SECRET} -n ${OPENMETADATA__NAMESPACE}
	-@helm uninstall opensearch -n ${OPENSEARCH__NAMESPACE}
	-@$(MAKE) destroy-virtualservice name=opensearch namespace=${OPENSEARCH__NAMESPACE}
	-@kubectl delete pvc -l app.kubernetes.io/instance=opensearch -n ${OPENSEARCH__NAMESPACE}
	@echo "✅ Opensearch uninstalled!"

# Openmetdata OIDC confidential flow
#	 	--set openmetadata.config.authentication.oidcConfiguration.oidcType=Keycloak \
#		--set openmetadata.config.authentication.oidcConfiguration.clientId=${OPENMETADATA__OIDC_CLIENT_ID}
#		--set openmetadata.config.authentication.oidcConfiguration.clientSecret=${OPENMETADATA__OIDC_CLIENT_SECRET}
#		--set openmetadata.config.authentication.oidcConfiguration.scope="openid email profile"
#		--set openmetadata.config.authentication.oidcConfiguration.discoveryUri=https://keycloak.${DOMAIN_HOST}/realms/${KEYCLOAK__REALM_NAME}/.well-known/openid-configuration
#		--set openmetadata.config.authentication.oidcConfiguration.callbackUrl=https://openmetadata.${DOMAIN_HOST}/callback
#		--set openmetadata.config.authentication.oidcConfiguration.serverUrl=https://openmetadata.${DOMAIN_HOST}

.PHONY: add-seaweedfs-repo
add-seaweedfs-repo: ## Add seaweedfs repo
	@helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm
	@helm repo update

.PHONY: install-seaweedfs
install-seaweedfs:
	@if [ ! -f "helm/seaweedfs/Chart.yaml" ]; then \
		echo "📦 Downloading seaweedfs/seaweedfs chart..."; \
		$(MAKE) add-seaweedfs-repo; \
		mkdir -p helm; \
		helm pull seaweedfs/seaweedfs --untar --untardir helm; \
		echo "✅ seaweedfs/seaweedfs chart downloaded to helm/seaweedfs/"; \
	else \
		echo "✅ seaweedfs/seaweedfs chart already exists (helm/seaweedfs/Chart.yaml found)"; \
	fi

.PHONY: seaweedfs
seaweedfs: install-seaweedfs
	@echo "🗄️ Installing SeaweedFS for object storage..."
	@set -a && source .env && set +a && envsubst < manifests/seaweedfs-config.yaml | helm upgrade --install seaweedfs seaweedfs/seaweedfs \
		-n ${SEAWEEDFS__NAMESPACE} --create-namespace -f -
	@echo "✅ SeaweedFS installation completed"

.PHONY: add-seaweedfs-csi-driver-repo
add-seaweedfs-csi-driver-repo: ## Add seaweedfs-csi-driver repo
	@helm repo add seaweedfs-csi-driver https://seaweedfs.github.io/seaweedfs-csi-driver/helm
	@helm repo update

.PHONY: install-seaweedfs-csi-driver
install-seaweedfs-csi-driver:
	@if [ ! -f "helm/seaweedfs-csi-driver/Chart.yaml" ]; then \
		echo "📦 Downloading seaweedfs-csi-driver/seaweedfs-csi-driver chart..."; \
		$(MAKE) add-seaweedfs-csi-driver-repo; \
		mkdir -p helm; \
		helm pull seaweedfs-csi-driver/seaweedfs-csi-driver --untar --untardir helm; \
		echo "✅ seaweedfs-csi-driver/seaweedfs-csi-driver chart downloaded to helm/seaweedfs-csi-driver/"; \
	else \
		echo "✅ seaweedfs-csi-driver/seaweedfs-csi-driver chart already exists (helm/seaweedfs-csi-driver/Chart.yaml found)"; \
	fi

.PHONY: seaweedfs-csi-driver
seaweedfs-csi-driver: install-seaweedfs-csi-driver
	@echo "💾 Installing SeaweedFS CSI Driver for RWX storage..."
	@helm upgrade --install seaweedfs-csi-driver seaweedfs-csi-driver/seaweedfs-csi-driver --version 0.2.3 \
		--namespace ${SEAWEEDFS__NAMESPACE} --create-namespace \
		--set seaweedfsFiler=seaweedfs-filer.${SEAWEEDFS__NAMESPACE}.svc.cluster.local:${SEAWEEDFS__FILER_HTTP_PORT} \
		--set csiAttacher.enabled=false \
		--set node.enabled=true \
		--set node.updateStrategy.type=OnDelete \
		--set storageClassName=${RWX_STORAGE_CLASS_NAME}
	@if kubectl get storageclass ${RWX_STORAGE_CLASS_NAME} >/dev/null 2>&1; then \
		echo "✅ SeaweedFS StorageClass is available (RWX support)"; \
	else \
		echo "❌ SeaweedFS StorageClass not found"; \
		echo "📋 Available StorageClasses:"; \
		kubectl get storageclass; \
		exit 1; \
	fi
	@echo "✅ SeaweedFS CSI Driver installation completed"

.PHONY: destroy-seaweedfs-csi-driver
destroy-seaweedfs-csi-driver: ## Destroy seaweedfs-csi-driver
	@helm uninstall seaweedfs-csi-driver -n ${SEAWEEDFS__NAMESPACE}
	@echo "✅ SeaweedFS CSI Driver uninstalled!"

.PHONY: destroy-seaweedfs
destroy-seaweedfs: ## Destroy seaweedfs
	@helm uninstall seaweedfs -n ${SEAWEEDFS__NAMESPACE}
	@echo "✅ SeaweedFS uninstalled!"

.PHONY: decode-token
decode-token: ## Decode token
	@if [ -z "${client-id}" ]; then \
		echo "❌ client-id is not set"; \
		exit 1; \
	fi; \
	if [ -z "${username}" ]; then \
		echo "❌ username is not set"; \
		exit 1; \
	fi; \
	if [ -z "${password}" ]; then \
		echo "❌ password is not set"; \
		exit 1; \
	fi; \
	echo "🔑 Decoding token for client: ${client-id}"
	@CLIENT_SECRET=$$(bash scripts/keycloak.sh get-client-secret ${client-id}); \
	if [ $$? -ne 0 ] || [ -z "$$CLIENT_SECRET" ]; then \
		echo "❌ Failed to get client secret from Keycloak"; \
		exit 1; \
	fi; \
	CLIENT_ID=${client-id} USERNAME=${username} PASSWORD=${password} DOMAIN_HOST=${DOMAIN_HOST} REALM_NAME=${KEYCLOAK__REALM_NAME} CLIENT_SECRET=$$CLIENT_SECRET set -a && source .env && set +a && bash scripts/token.sh
