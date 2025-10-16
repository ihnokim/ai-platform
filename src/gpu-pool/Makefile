.PHONY: help build deploy test clean logs

DOCKER_IMAGE ?= cr.makina.rocks/inho.kim/gpu-pool-webhook:0.1.0
NAMESPACE ?= gpu-pool

help: ## Show this help message
	@echo "GPU Pool Mutating Webhook"
	@echo ""
	@echo "Available commands:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build the webhook Docker image
	@echo "🔨 Building webhook image..."
	@go mod tidy
	@docker build --platform linux/amd64 -t $(DOCKER_IMAGE) .
	@echo "✅ Image built: $(DOCKER_IMAGE)"

build-local:
	@go build -v .

push:
	@echo "🔓 Pushing image to registry..."
	docker push $(DOCKER_IMAGE)
	@echo "✅ Image pushed: $(DOCKER_IMAGE)"

generate-certs: ## Generate TLS certificates for webhook
	@echo "🔐 Generating TLS certificates..."
	./generate-certs.sh

ca-bundle:
	@kubectl get secret gpu-pool-webhook-certs -n gpu-pool -o jsonpath='{.data.tls\.crt}' | base64 -d | base64 | tr -d '\n'

deploy: ## Deploy the webhook to Kubernetes
	@echo "🚀 Deploying webhook..."
	kubectl apply -f deployment.yaml
	@echo "⏳ Waiting for deployment to be ready..."
	kubectl wait --for=condition=available --timeout=60s deployment/gpu-pool-webhook -n $(NAMESPACE)
	@echo "✅ Webhook deployed successfully!"

deploy-config: ## Deploy the webhook configuration (requires caBundle)
	@echo "🔧 Deploying webhook configuration..."
	@echo "⚠️  Make sure to add caBundle to webhook-config.yaml first!"
	kubectl apply -f webhook-config.yaml
	@echo "✅ Webhook configuration deployed!"

test: ## Apply test examples
	@echo "🧪 Applying test examples..."
	kubectl apply -f test-examples.yaml
	@echo "✅ Test pods created!"

check-test: ## Check test results
	@echo "🔍 Checking test results..."
	@echo ""
	@echo "=== Pod with annotation 'inho: message' (should have label 'inho: hello') ==="
	kubectl get pod test-pod-with-annotation -o jsonpath='{.metadata.labels}' | jq . || echo "Pod not found"
	@echo ""
	@echo "=== Pod without annotation (should have no 'inho' label) ==="
	kubectl get pod test-pod-without-annotation -o jsonpath='{.metadata.labels}' | jq . || echo "Pod not found"
	@echo ""
	@echo "=== Pod with wrong annotation value (should have no 'inho' label) ==="
	kubectl get pod test-pod-wrong-annotation -o jsonpath='{.metadata.labels}' | jq . || echo "Pod not found"
	@echo ""
	@echo "=== Pod with existing labels (should have 'inho: hello' added) ==="
	kubectl get pod test-pod-with-existing-labels -o jsonpath='{.metadata.labels}' | jq . || echo "Pod not found"

logs: ## Show webhook logs
	@echo "📋 Webhook logs:"
	kubectl logs -l app=gpu-pool-webhook -n $(NAMESPACE) --tail=50 -f

clean-test: ## Clean up test pods
	@echo "🧹 Cleaning up test pods..."
	kubectl delete -f test-examples.yaml --ignore-not-found=true
	@echo "✅ Test pods cleaned up!"

clean: ## Clean up all resources
	@echo "🧹 Cleaning up webhook resources..."
	kubectl delete -f webhook-config.yaml --ignore-not-found=true
	kubectl delete -f deployment.yaml --ignore-not-found=true
	@echo "✅ Resources cleaned up!"

status: ## Show webhook status
	@echo "📊 Webhook Status:"
	@echo ""
	@echo "=== Namespace ==="
	kubectl get namespace $(NAMESPACE) || echo "Namespace not found"
	@echo ""
	@echo "=== Deployment ==="
	kubectl get deployment -n $(NAMESPACE) || echo "No deployments found"
	@echo ""
	@echo "=== Pods ==="
	kubectl get pods -n $(NAMESPACE) || echo "No pods found"
	@echo ""
	@echo "=== Service ==="
	kubectl get service -n $(NAMESPACE) || echo "No services found"
	@echo ""
	@echo "=== Webhook Configuration ==="
	kubectl get mutatingadmissionwebhook gpu-pool-webhook || echo "Webhook config not found"

# Development commands
dev-build: ## Build and load image for local development
	@echo "🔨 Building for local development..."
	docker build -t $(DOCKER_IMAGE) .
	@if command -v kind >/dev/null 2>&1; then \
		echo "📦 Loading image to kind cluster..."; \
		kind load docker-image $(DOCKER_IMAGE); \
	fi
	@echo "✅ Development build complete!"

dev-deploy: dev-build generate-certs deploy ## Full development deployment
	@echo "🎉 Development deployment complete!"
	@echo "💡 Don't forget to update webhook-config.yaml with caBundle and run 'make deploy-config'"
