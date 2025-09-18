# Runway Platform

A comprehensive Kubernetes platform with integrated authentication, Git hosting, and workflow management.

## Features

- 🔐 **Keycloak Integration**: Centralized authentication and authorization
- 🐙 **Gitea**: Self-hosted Git service with OIDC integration
- ☁️ **Kubernetes OIDC**: kubectl authentication via Keycloak
- 🚀 **Airflow**: Workflow orchestration and scheduling
- 🗄️ **PostgreSQL**: CloudNativePG for high availability
- 🌐 **Istio**: Service mesh and traffic management

## Quick Start

### Prerequisites

- Docker Desktop with Kubernetes enabled
- k3d for local cluster management
- Helm 3.x
- kubectl
- make

### Setup

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd runway-platform
   ```

2. **Configure environment**
   ```bash
   cp .env.example .env
   # Edit .env with your configuration
   ```

3. **Start the platform**
   ```bash
   make test-cluster    # Create local Kubernetes cluster
   make istio          # Install Istio service mesh
   make cnpg           # Install PostgreSQL cluster
   make keycloak       # Install Keycloak
   make gitea          # Install Gitea with OIDC
   make k8s-oidc       # Setup Kubernetes OIDC authentication
   ```

4. **Authenticate with kubectl**
   ```bash
   make k8s-oidc-auth
   # Follow the prompts to authenticate
   ```

## Authentication

### Keycloak OIDC Integration

The platform uses Keycloak as the central identity provider with OIDC integration for:

- **Gitea**: Git repository access via Keycloak login
- **Kubernetes**: kubectl authentication via OIDC tokens
- **Airflow**: Workflow access control

### User Groups

| Group | Permissions | Description |
|-------|-------------|-------------|
| `runway-developers` | Read-only | View resources, logs, and status |
| `runway-operators` | Limited write | Deploy and manage applications |
| `runway-admins` | Full access | Complete cluster administration |

### Sample Users

| Username | Password | Group | Access |
|----------|----------|-------|--------|
| `developer` | `developer123` | `runway-developers` | Read-only |
| `k8s-admin` | `admin123` | `runway-admins` | Full access |

## Services

### Keycloak
- **URL**: https://keycloak.runway.local
- **Admin Console**: https://keycloak.runway.local/auth/admin
- **Realm**: `runway`

### Gitea
- **URL**: https://gitea.runway.local
- **Admin**: `gitea_admin` / `r8sA8CPHD9!bt6d`

### Airflow
- **URL**: https://airflow.runway.local
- **Admin**: Configured via environment variables

## Development

### Local Development

1. **Start DNS resolution**
   ```bash
   make dns
   ```

2. **Access services**
   - All services are accessible via `*.runway.local` domains
   - DNS automatically resolves to local cluster

3. **Stop services**
   ```bash
   make destroy-dns
   ```

### Kubernetes OIDC Authentication

1. **Setup OIDC client**
   ```bash
   make k8s-oidc-setup
   ```

2. **Apply RBAC rules**
   ```bash
   make k8s-oidc-rbac
   ```

3. **Authenticate**
   ```bash
   make k8s-oidc-auth
   ```

4. **Test access**
   ```bash
   kubectl get pods
   kubectl auth can-i get nodes
   ```

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Keycloak      │    │   Kubernetes    │    │   Applications  │
│   (OIDC)        │◄──►│   (OIDC Auth)   │◄──►│   (Gitea, etc.) │
└─────────────────┘    └─────────────────┘    └─────────────────┘
        │                       │                       │
        │                       │                       │
        ▼                       ▼                       ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   User Groups   │    │   RBAC Rules    │    │   Service Mesh  │
│   & Permissions │    │   & Policies    │    │   (Istio)       │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

## Configuration

### Environment Variables

Key configuration variables in `.env`:

```bash
# Domain configuration
DOMAIN_HOST=runway.local

# Keycloak
KEYCLOAK__NAMESPACE=keycloak
KEYCLOAK__REALM_NAME=runway
KEYCLOAK__ADMIN_USERNAME=admin
KEYCLOAK__ADMIN_PASSWORD=admin123

# Gitea
GITEA__NAMESPACE=gitea
GITEA__ADMIN_USERNAME=gitea_admin
GITEA__ADMIN_PASSWORD=r8sA8CPHD9!bt6d

# Database
CNPG__CLUSTER_NAMESPACE=postgres
CNPG__ADMIN_USERNAME=postgres
CNPG__ADMIN_PASSWORD=postgres123
```

### Customization

- **Add new services**: Create Helm charts in `helm/` directory
- **Modify RBAC**: Update `manifests/k8s-oidc-config.yaml`
- **Configure OIDC**: Modify `scripts/keycloak-k8s-setup.sh`

## Troubleshooting

### Common Issues

1. **DNS Resolution**
   ```bash
   # Check DNS configuration
   nslookup keycloak.runway.local
   
   # Restart DNS
   make destroy-dns && make dns
   ```

2. **Authentication Issues**
   ```bash
   # Check Keycloak status
   kubectl get pods -n keycloak
   
   # Verify OIDC configuration
   curl https://keycloak.runway.local/auth/realms/runway/.well-known/openid-configuration
   ```

3. **Kubernetes Access**
   ```bash
   # Check current context
   kubectl config current-context
   
   # Re-authenticate
   make k8s-oidc-auth
   ```

### Logs

```bash
# Keycloak logs
kubectl logs -n keycloak -l app.kubernetes.io/name=keycloak

# Gitea logs
kubectl logs -n gitea -l app.kubernetes.io/name=gitea

# API server logs
kubectl logs -n kube-system kube-apiserver-<node-name>
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with `make test-cluster`
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Support

For issues and questions:
- Check the troubleshooting section
- Review the documentation in `docs/`
- Open an issue on GitHub
