include .env

.PHONY: help root-ca csr cert ca tls test-cluster destroy-test-cluster auth-test dns destroy-dns cnpg destroy-cnpg database k8s-oidc-setup k8s-oidc-auth k8s-oidc-rbac

help: ## Show available commands
	@echo "Commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

dependency:
	@if kubectl oidc-login --version >/dev/null 2>&1; then \
		echo "✅ Kubectl oidc-login is installed"; \
	else \
		echo "❌ Kubectl oidc-login is not installed"; \
		exit 1; \
	fi

root-ca: ## Create root CA
	@mkdir -p ./certs
	@openssl genrsa -out ./certs/root-ca.key 4096;
	@openssl req -x509 -new -key ./certs/root-ca.key -sha256 -days 3650 -out ./certs/root-ca.pem \
		-subj "/CN=Runway Root CA/O=Runway Platform/L=Gangnam/ST=Seoul/C=KR" \
		-addext "basicConstraints=critical,CA:TRUE" \
		-addext "keyUsage=critical,keyCertSign,cRLSign";

csr: ## Create CSR for *.${DOMAIN_HOST}
	@echo "📄 Creating CSR for *.${DOMAIN_HOST}..."
	@openssl genrsa -out ./certs/${CLUSTER_NAME}-key.pem 4096;
	@openssl req -new -key ./certs/${CLUSTER_NAME}-key.pem -out ./certs/${CLUSTER_NAME}.csr \
		-subj "/CN=*.${DOMAIN_HOST}/OU=Platform Infrastructure/O=Runway Platform/L=Gangnam/ST=Seoul/C=KR" \
		-addext "subjectAltName=DNS:*.${DOMAIN_HOST},DNS:${DOMAIN_HOST},DNS:*.serving.${DOMAIN_HOST}"

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

deprecated-issue-cert: ## Issue certificate
	@mkdir -p ./certs
	@openssl req -x509 -newkey rsa:4096 -keyout ./certs/${CLUSTER_NAME}-key.pem -out ./certs/${CLUSTER_NAME}-cert.pem \
		-days 365 -nodes \
		-subj "/CN=*.${DOMAIN_HOST}/OU=Platform Infrastructure/O=Runway Platform/L=Gangnam/ST=Seoul/C=KR" \
		-addext "subjectAltName=DNS:*.${DOMAIN_HOST},DNS:${DOMAIN_HOST}";

deprecated-apply-cert: ## Apply certificate
	@if [ "$$(uname)" = "Darwin" ] && [ -f ./certs/${CLUSTER_NAME}-cert.pem ]; then \
		echo "🍎 Updating certificate in macOS Keychain..."; \
		sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ./certs/${CLUSTER_NAME}-cert.pem && \
		echo "✅ Certificate updated in macOS System Keychain" || \
		echo "⚠️  Failed to update certificate in macOS Keychain (requires sudo)"; \
	elif [ "$$(uname)" != "Darwin" ]; then \
		echo "ℹ️  macOS certificate installation skipped (not macOS)"; \
	fi

apply-cert:
	@if [ "$$(uname)" = "Darwin" ] && [ -f ./certs/root-ca.pem ]; then \
		echo "🍎 Updating Root CA certificate in macOS Keychain..."; \
		sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ./certs/root-ca.pem && \
		echo "✅ Root CA certificate updated in macOS System Keychain" || \
		echo "⚠️  Failed to update Root CA certificate in macOS Keychain (requires sudo)"; \
	elif [ "$$(uname)" != "Darwin" ]; then \
		echo "ℹ️  macOS certificate installation skipped (not macOS)"; \
	fi

deprecated-cert: deprecated-issue-cert deprecated-apply-cert

cert: root-ca csr sign-cert apply-cert ## Issue and apply certificate

deprecated-find-cert:
	@security find-certificate -c "${DOMAIN_HOST}" /Library/Keychains/System.keychain

find-cert:
	@security find-certificate -c "Runway" /Library/Keychains/System.keychain

delete-cert: ## Open Keychain Access for manual certificate deletion
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

copy-tls: ## Copy TLS secret from istio-system to gitea namespace
	@echo "📋 Copying TLS secret from istio-system to ${namespace} namespace..."
	@kubectl get secret ${CLUSTER_NAME}-tls -n ${ISTIO__NAMESPACE} -o yaml | \
		sed 's/namespace: ${ISTIO__NAMESPACE}/namespace: ${namespace}/' | \
		kubectl apply -f -
	@echo "✅ TLS secret copied to ${namespace} namespace"

ca: ## Create CA secret
	-@kubectl create namespace ${namespace}
	@kubectl create secret generic ${CLUSTER_NAME}-ca \
		-n ${namespace} \
		--from-file=ca.crt=./certs/${CLUSTER_NAME}-cert.pem

# --k3s-arg '--kube-apiserver-arg=oidc-ca-file=/tmp/${CLUSTER_NAME}-certs/${CLUSTER_NAME}-cert.pem@server:*'

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

kubeconfig-admin:
	@k3d kubeconfig get ${CLUSTER_NAME} > ~/.kube/config

kubeconfig-user:
	@cat ./.kube/config > ~/.kube/config

kubelogin-decoded-token:
	@kubectl oidc-login get-token \
		--oidc-issuer-url=https://keycloak.${DOMAIN_HOST}/realms/${KEYCLOAK__REALM_NAME} \
		--oidc-client-id=kubernetes \
		--insecure-skip-tls-verify -v=0 \
		| jq -r '.status.token | split(".")[1] | @base64d | fromjson'

kubelogout:
	@rm -rf ~/.kube/cache/oidc-login/*

auth-test: ## Deploy auth-test app
	@helm upgrade --install auth-test helm/auth-test \
		--namespace auth \
		--create-namespace \
		--set virtualService.domain=${DOMAIN_HOST}
	@echo "✅ Auth test app installed!"

destroy-auth-test: ## Destroy auth-test app
	@helm uninstall auth-test --namespace auth
	@echo "✅ Auth test app uninstalled!"

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
	echo "🧹 Removing existing runway-platform entries..."; \
	sudo sed -i '' '/runway-platform\/dnsmasq.*\.conf/d' "$$MAIN_CONF" 2>/dev/null || true; \
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

destroy-dns: ## Cleanup dnsmasq configuration
	@echo "🧹 Cleaning up dnsmasq configuration..."
	@PROJECT_CONF="$(shell pwd)/dnsmasq.conf"; \
	MAIN_CONF="$$(brew --prefix)/etc/dnsmasq.conf"; \
	echo "🗑️  Removing runway-platform entries from $$MAIN_CONF..."; \
	sudo sed -i '' '/runway-platform\/dnsmasq.*\.conf/d' "$$MAIN_CONF" 2>/dev/null || true; \
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

internal-dns: ## Setup internal DNS for local development
	@echo "🚀 Setting up internal DNS for local development..."
	@echo "🌐 Using domain: ${DOMAIN_HOST}"
	@echo "🔧 Generating internal DNS configuration..."
	@echo "📝 Creating CoreDNS configuration with template plugin..."
	@DOMAIN_HOST=${DOMAIN_HOST} ISTIO__NAMESPACE=${ISTIO__NAMESPACE} bash scripts/coredns-custom.sh
	@echo "✅ Internal DNS setup complete!"
# NOTE: kubectl rollout restart deployment coredns -n kube-system

destroy-internal-dns: ## Destroy internal DNS for local development
	@echo "🧹 Cleaning up internal DNS configuration..."
	@kubectl delete configmap coredns-custom -n kube-system
	@echo "✅ Internal DNS cleanup complete!"

test-internal-dns:
	@GITEA_POD_NAME=$$(kubectl get pods -n gitea -o jsonpath='{.items[0].metadata.name}'); \
	kubectl exec -n gitea $$GITEA_POD_NAME -- nslookup keycloak.runway.ai

current-internal-dns:
	@kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}'

add-istio-repo: ## Add istio repo
	@helm repo add istio https://istio-release.storage.googleapis.com/charts
	@helm repo update

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

install-istio: install-istio-base install-istio-istiod install-istio-gateway ## Install istio charts

runway-gateway: deprecated-tls ## Deploy runway gateway chart
	@helm upgrade --install runway-gateway helm/istio/runway-gateway \
		--namespace ${ISTIO__NAMESPACE} --create-namespace \
		--set host=${DOMAIN_HOST} \
		--set tls.enabled=true \
		--set tls.credentialName=${CLUSTER_NAME}-tls

istio: install-istio ## Deploy istio base and istiod charts
	@helm upgrade --install istio-base helm/istio/base -n ${ISTIO__NAMESPACE} --create-namespace
	@helm upgrade --install istio-istiod helm/istio/istiod -n ${ISTIO__NAMESPACE} --create-namespace
	@helm upgrade --install istio-gateway helm/istio/gateway -n ${ISTIO__NAMESPACE} --create-namespace
	@$(MAKE) runway-gateway
	@$(MAKE) internal-dns

add-cnpg-repo: ## Add cnpg repo
	@helm repo add cnpg https://cloudnative-pg.github.io/charts
	@helm repo update

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

install-cnpg: install-cnpg-cloudnative-pg install-cnpg-cluster ## Install cnpg charts

#		--set cluster.initdb.postInitSQL[0]="CREATE DATABASE ${KEYCLOAK__DATABASE_NAME};" \
#		--set cluster.initdb.postInitSQL[1]="CREATE DATABASE ${GITEA__DATABASE_NAME};" \
#		--set cluster.initdb.postInitSQL[2]="GRANT ALL PRIVILEGES ON SCHEMA ${CNPG__DATABASE_SCHEMA} TO ${CNPG__ADMIN_USERNAME};" \
#		--set cluster.initdb.postInitSQL[3]="GRANT ALL PRIVILEGES ON DATABASE ${KEYCLOAK__DATABASE_NAME} TO ${CNPG__ADMIN_USERNAME};" \
#		--set cluster.initdb.postInitSQL[4]="GRANT ALL PRIVILEGES ON DATABASE ${GITEA__DATABASE_NAME} TO ${CNPG__ADMIN_USERNAME};" \

cnpg: install-cnpg ## Install cnpg charts
	@helm upgrade --install cnpg-cloudnative-pg helm/cnpg/cloudnative-pg -n ${CNPG__OPERATOR_NAMESPACE} --create-namespace --wait
#	--set config.clusterWide=false \
#	--set config.data.WATCH_NAMESPACE=${CNPG__CLUSTER_NAMESPACE}
# TODO: enable backups
# TODO: enable recovery
	@echo "🔐 Creating admin user secret..."
	@kubectl create namespace ${CNPG__CLUSTER_NAMESPACE} || true
	@kubectl create secret generic ${CNPG__ADMIN_SECRET} \
		--from-literal=username=${CNPG__ADMIN_USERNAME} \
		--from-literal=password=${CNPG__ADMIN_PASSWORD} \
		--type=kubernetes.io/basic-auth \
		-n ${CNPG__CLUSTER_NAMESPACE} \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "✅ Admin user secret created!"
	@helm upgrade --install cnpg-cluster helm/cnpg/cluster \
		-n ${CNPG__CLUSTER_NAMESPACE} --create-namespace \
		--set cluster.initdb.database=${CNPG__DATABASE_NAME} \
		--set cluster.initdb.owner=${CNPG__ADMIN_USERNAME} \
		--set cluster.initdb.secret.name=${CNPG__ADMIN_SECRET} \
		--set cluster.enableSuperuserAccess=true \
		--set cluster.initdb.postInitSQL[0]="ALTER USER ${CNPG__ADMIN_USERNAME} WITH SUPERUSER;" \
		--set poolers[0].name=rw \
		--set poolers[0].type=rw \
		--set poolers[0].poolMode=transaction \
		--set poolers[0].instances=3 \
		--set-string poolers[0].parameters.max_client_conn=100 \
		--set-string poolers[0].parameters.default_pool_size=10 \
		--set poolers[0].monitoring.enabled=false \
		--set poolers[0].monitoring.podMonitor.enabled=true \
		--set poolers[1].name=ro \
		--set poolers[1].type=ro \
		--set poolers[1].poolMode=transaction \
		--set poolers[1].instances=3 \
		--set-string poolers[1].parameters.max_client_conn=200 \
		--set-string poolers[1].parameters.default_pool_size=20 \
		--set poolers[1].monitoring.enabled=false \
		--set poolers[1].monitoring.podMonitor.enabled=true
# TODO: enable monitoring
# TODO: enable logging

destroy-cnpg: ## Destroy cnpg cluster and operator
	@echo "🗑️  Removing CNPG cluster..."
	@helm uninstall cnpg-cluster -n ${CNPG__CLUSTER_NAMESPACE} 2>/dev/null || echo "cnpg-cluster not found"
	@echo "🗑️  Removing admin secret..."
	@kubectl delete secret ${CNPG__ADMIN_SECRET} -n ${CNPG__CLUSTER_NAMESPACE} 2>/dev/null || echo "runway-admin-secret not found"
	@echo "🗑️  Removing CNPG operator..."
	@helm uninstall cnpg-cloudnative-pg -n ${CNPG__OPERATOR_NAMESPACE} 2>/dev/null || echo "cnpg-cloudnative-pg not found"
	@echo "✅ CNPG cleanup complete!"

database: ## Create database
	@if [ -z "${name}" ]; then \
		echo "❌ Error: name is not set or empty"; \
		echo "💡 Usage: make database name=your_database_name"; \
		exit 1; \
	fi
	@echo "🔐 Creating database: ${name}..."
	@kubectl exec -n ${CNPG__CLUSTER_NAMESPACE} cnpg-cluster-1 -c postgres -- bash -c "export PGPASSWORD='${CNPG__ADMIN_PASSWORD}' && psql -h localhost -U ${CNPG__ADMIN_USERNAME} -d ${CNPG__DATABASE_NAME} -c \"CREATE DATABASE ${name};\"" 2>/dev/null && echo "✅ Database ${name} created" || echo "⚠️  Database ${name} already exists"
#	@echo "🔐 Granting privileges to ${name}..."
#	@kubectl exec -n ${CNPG__CLUSTER_NAMESPACE} cnpg-cluster-1 -c postgres -- bash -c "export PGPASSWORD='${CNPG__ADMIN_PASSWORD}' && psql -U ${CNPG__ADMIN_USERNAME} -d ${CNPG__DATABASE_NAME} -c \"GRANT ALL PRIVILEGES ON DATABASE ${name} TO ${CNPG__ADMIN_USERNAME};\""
	@echo "✅ Database ${name} created and configured!"

add-keycloak-repo: ## Add keycloak repo
	@helm repo add bitnami https://charts.bitnami.com/bitnami
	@helm repo update

# TODO: keycloak
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

keycloak-vs: ## Deploy keycloak virtual service
	@set -a && source .env && set +a && envsubst < manifests/keycloak-vs.yaml | kubectl apply -f -
	@echo "✅ Keycloak virtual service deployed!"

destroy-keycloak-vs: ## Destroy keycloak virtual service
	@kubectl delete virtualservice keycloak -n ${KEYCLOAK__NAMESPACE}
	@echo "✅ Keycloak virtual service destroyed!"

# TODO: values set 값들 수정해야 함
keycloak: install-keycloak ## Install keycloak chart
	@$(MAKE) database name=${KEYCLOAK__DATABASE_NAME}
	@helm upgrade --install keycloak helm/keycloak \
		-n ${KEYCLOAK__NAMESPACE} --create-namespace \
		--set replicaCount=3 \
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
	@$(MAKE) keycloak-vs
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

destroy-keycloak: ## Destroy keycloak
	@helm uninstall keycloak -n ${KEYCLOAK__NAMESPACE}
	@$(MAKE) destroy-keycloak-vs
	@echo "✅ Keycloak uninstalled!"

add-gitea-repo: ## Add gitea repo
	@helm repo add gitea-charts https://dl.gitea.com/charts/
	@helm repo update

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
gitea: install-gitea ## Install gitea chart
	-@$(MAKE) ca namespace=${GITEA__NAMESPACE}
	@$(MAKE) database name=${GITEA__DATABASE_NAME}
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
		--set gitea.oauth[0].name=Keycloak \
		--set gitea.oauth[0].provider=openidConnect \
		--set gitea.oauth[0].key=gitea \
		--set gitea.oauth[0].secret=$$GITEA__CLIENT_SECRET \
		--set gitea.oauth[0].autoDiscoverUrl=https://keycloak.${DOMAIN_HOST}/realms/${KEYCLOAK__REALM_NAME}/.well-known/openid-configuration \
		--set gitea.oauth[0].scopes="openid profile email" \
		--set gitea.config.server.ROOT_URL=https://gitea.${DOMAIN_HOST}/ \
		--set deployment.env[0].name=SSL_CERT_FILE \
		--set deployment.env[0].value=/etc/ssl/certs/${CLUSTER_NAME}-ca.crt \
		--set extraVolumes[0].name=${CLUSTER_NAME}-ca \
		--set extraVolumes[0].secret.secretName=${CLUSTER_NAME}-ca \
		--set extraVolumes[0].secret.items[0].key=ca.crt \
		--set extraVolumes[0].secret.items[0].path=${CLUSTER_NAME}-ca.crt \
		--set extraVolumeMounts[0].name=${CLUSTER_NAME}-ca \
		--set extraVolumeMounts[0].mountPath=/etc/ssl/certs/${CLUSTER_NAME}-ca.crt \
		--set extraVolumeMounts[0].subPath=${CLUSTER_NAME}-ca.crt \
		--set extraVolumeMounts[0].readOnly=true
	@$(MAKE) gitea-vs
	@echo "✅ Gitea installed!"

destroy-gitea: ## Destroy gitea chart
	@helm uninstall gitea -n ${GITEA__NAMESPACE}
	@$(MAKE) destroy-gitea-vs
	@echo "✅ Gitea uninstalled!"

gitea-vs: ## Deploy gitea virtual service
	@set -a && source .env && set +a && envsubst < manifests/gitea-vs.yaml | kubectl apply -f -
	@echo "✅ Gitea virtual service deployed!"

destroy-gitea-vs: ## Destroy gitea virtual service
	@kubectl delete virtualservice gitea -n ${GITEA__NAMESPACE}
	@echo "✅ Gitea virtual service destroyed!"

add-airflow-repo: ## Add airflow repo
	@helm repo add apache-airflow https://airflow.apache.org
	@helm repo update

install-airflow: ## Install airflow chart
	@if [ ! -f "helm/airflow/Chart.yaml" ]; then \
		echo "📦 Downloading apache-airflow/airflow chart..."; \
		$(MAKE) add-airflow-repo; \
		mkdir -p helm; \
		helm pull apache-airflow/airflow --untar --untardir helm; \
		echo "✅ apache-airflow/airflow chart downloaded to helm/airflow/"; \
	fi

airflow-vs: ## Deploy airflow virtual service
	@set -a && source .env && set +a && envsubst < manifests/airflow-vs.yaml | kubectl apply -f -
	@echo "✅ Airflow virtual service deployed!"

destroy-airflow-vs: ## Destroy airflow virtual service
	@kubectl delete virtualservice airflow -n ${AIRFLOW__NAMESPACE}
	@echo "✅ Airflow virtual service destroyed!"

airflow: install-airflow ## Install airflow chart
# --set brokerdata.brokerUrl=redis://redis-master:6379/0
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
		--set data.metadataConnection.host=${AIRFLOW__DATABASE_HOST} \
		--set data.metadataConnection.port=${AIRFLOW__DATABASE_PORT} \
		--set data.metadataConnection.db=${AIRFLOW__DATABASE_NAME} \
		--set data.metadataConnection.protocol=${AIRFLOW__DATABASE_PROTOCOL} \
		--set data.metadataConnection.user=${AIRFLOW__DATABASE_USERNAME} \
		--set data.metadataConnection.pass=${AIRFLOW__DATABASE_PASSWORD} \
		--set data.metadataConnection.sslmode=${AIRFLOW__DATABASE_SSL_MODE} \
		--set ports.airflowUI=${AIRFLOW__HTTP_PORT} \
		--set workers.replicas=${AIRFLOW__WORKERS_REPLICAS}
	@$(MAKE) airflow-vs
	@echo "✅ Airflow installed!"

destroy-airflow: ## Destroy airflow chart
	@helm uninstall airflow -n ${AIRFLOW__NAMESPACE}
	@$(MAKE) destroy-airflow-vs
	@echo "✅ Airflow uninstalled!"
