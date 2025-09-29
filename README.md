# AI Platform

A comprehensive multi-tenant, on-premise Kubernetes platform that provides integrated authentication-based Git hosting, workflow management, and execution environment for applications and AI models.

## Overview

This platform delivers a complete enterprise-grade solution for organizations seeking a unified, self-hosted development and deployment environment with the following key capabilities:

### 🏢 Multi-Tenancy Support
- **Isolated Namespaces**: Complete resource isolation between tenants
- **RBAC Integration**: Fine-grained role-based access control per tenant
- **Quota Management**: Resource limits and quotas per tenant organization

### 🔐 Integrated Authentication & Authorization
- **Centralized Identity Management**: Keycloak-based SSO across all platform services
- **OIDC Integration**: Standards-based authentication for Kubernetes API and applications
- **Fine-grained Permissions**: Project-level and service-level access control
- **External Identity Providers**: Support for LDAP, SAML, and social login integration

### 🛠️ Git Hosting & Repository Management
- **Enterprise Git Server**: Self-hosted Gitea with OAuth2 integration
- **Repository Isolation**: Per-tenant repository access and management
- **Pull Request Workflows**: Built-in code review and collaboration features
- **Git-based CI/CD Triggers**: Automated workflow triggering from repository events

### ⚙️ Workflow Management & Orchestration
- **Apache Airflow Integration**: Sophisticated DAG-based workflow orchestration
- **Multi-tenant Workflows**: Isolated workflow execution per tenant
- **Metadata Management**: OpenMetadata for comprehensive data lineage and governance
- **Search & Discovery**: Opensearch-powered metadata search and analytics

### 🚀 Application & AI Model Execution
- **Containerized Workloads**: Full support for Docker and OCI containers
- **AI/ML Model Serving**: Optimized environment for machine learning model deployment
- **Auto-scaling**: Horizontal and vertical pod autoscaling based on demand
- **Service Mesh**: Istio-based traffic management and observability
- **Storage Solutions**: Distributed object storage with SeaweedFS

### 🗄️ Data Management
- **PostgreSQL Clusters**: High-availability database clusters with CloudNative-PG
- **Object Storage**: S3-compatible distributed storage for large datasets
- **Data Lineage**: Complete tracking of data flows and transformations
- **Backup & Recovery**: Automated backup strategies for critical data

## Quick Start

### Prerequisites

- Docker
- k3d for local cluster management
- Helm 3.x
- make
- kubectl with oidc-login plugin
- jq for JSON processing

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with ```make test-cluster```
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.
