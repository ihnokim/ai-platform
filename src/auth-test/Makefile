# Docker image settings
IMAGE_REPOSITORY ?= ihnokim/auth-test
IMAGE_TAG ?= 0.1.0
PLATFORMS = linux/amd64,linux/arm64

.PHONY: help build push test clean setup-buildx dev install format lint release

help: ## Show available commands
	@echo "Commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup-buildx: ## Setup Docker buildx for multi-platform builds
	@echo "🔧 Setting up Docker buildx..."
	docker buildx create --name multiarch --driver docker-container --use || true
	docker buildx inspect multiarch --bootstrap

build: setup-buildx ## Build multi-platform images (ARM64 + AMD64)
	docker build --no-cache --platform linux/amd64 -t ${IMAGE_REPOSITORY}:${IMAGE_TAG}-amd64 .
	docker build --no-cache --platform linux/arm64 -t ${IMAGE_REPOSITORY}:${IMAGE_TAG}-arm64 .

push: ## Push images to registry
	-docker manifest rm $(IMAGE_REPOSITORY):$(IMAGE_TAG)
	docker push ${IMAGE_REPOSITORY}:${IMAGE_TAG}-amd64
	docker push ${IMAGE_REPOSITORY}:${IMAGE_TAG}-arm64
	docker manifest create ${IMAGE_REPOSITORY}:${IMAGE_TAG} \
		--amend ${IMAGE_REPOSITORY}:${IMAGE_TAG}-amd64 \
		--amend ${IMAGE_REPOSITORY}:${IMAGE_TAG}-arm64
	docker manifest push ${IMAGE_REPOSITORY}:${IMAGE_TAG}

inspect: ## Inspect multi-platform manifest
	@echo "🔍 Inspecting multi-platform manifest..."
	docker buildx imagetools inspect $(IMAGE_REPOSITORY):$(IMAGE_TAG)

test: ## Run the image locally for testing
	@echo "🧪 Running image locally..."
	@echo "URL: http://localhost:8000"
	docker run --rm -p 8000:8000 $(IMAGE_REPOSITORY):$(IMAGE_TAG)

clean: ## Clean up build artifacts and builders
	@echo "🧹 Cleaning up..."
	docker buildx rm multiarch || true
	docker system prune -f
	@echo "✅ Cleanup complete"

dev: ## Start development server with hot reload
	poetry run uvicorn main:app --host 0.0.0.0 --port 8000 --reload

install: ## Install dependencies
	poetry install

format: ## Format code with black and isort
	poetry run black .
	poetry run isort .

lint: ## Run linting
	poetry run flake8 .

release: build push ## Build and push multi-platform images
	@echo "🎉 Release complete!"
	@echo "Image: $(IMAGE_REPOSITORY):$(IMAGE_TAG)"
	@echo "Platforms: linux/amd64, linux/arm64"
