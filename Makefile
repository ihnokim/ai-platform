include .env

.PHONY: help hello test-cluster destroy-test-cluster auth-test dns destroy-dns cnpg destroy-cnpg database

help: ## Show available commands
	@echo "Commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

test-cluster: ## Install test cluster
	@if ! k3d cluster list ${CLUSTER_NAME}; then \
	  k3d cluster create ${CLUSTER_NAME} \
	  --agents ${TEST_CLUSTER__WORKER_NODES} \
		--registry-config "registry.yaml" \
		--port "80:80@server:0:direct" \
		--port "443:443@server:0:direct" \
		-i --k3s-arg "--image=${TEST_CLUSTER__IMAGE}" \
		--k3s-arg '--disable=traefik@server:*'; \
	fi

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

kubeconfig:
	@k3d kubeconfig get ${CLUSTER_NAME} > ~/.kube/config

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

runway-gateway: ## Deploy runway gateway chart
	@helm upgrade --install runway-gateway helm/istio/runway-gateway \
		--namespace ${ISTIO__NAMESPACE} --create-namespace \
		--set host=${DOMAIN_HOST}

istio: install-istio ## Deploy istio base and istiod charts
	@helm upgrade --install istio-base helm/istio/base -n ${ISTIO__NAMESPACE} --create-namespace
	@helm upgrade --install istio-istiod helm/istio/istiod -n ${ISTIO__NAMESPACE} --create-namespace
	@helm upgrade --install istio-gateway helm/istio/gateway -n ${ISTIO__NAMESPACE} --create-namespace
	@$(MAKE) runway-gateway

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
		--set auth.adminPassword=${KEYCLOAK__ADMIN_PASSWORD}
	@$(MAKE) keycloak-vs
	@echo "✅ Keycloak installed!"

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

gitea: install-gitea ## Install gitea chart
	@$(MAKE) database name=${GITEA__DATABASE_NAME}
	@helm upgrade --install gitea helm/gitea \
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
		--set gitea.config.database.PASSWD=${GITEA__DATABASE_PASSWORD}
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
