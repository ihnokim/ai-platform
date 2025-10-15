#!/bin/bash

# Webhook TLS 인증서 문제 해결 스크립트
set -e

NAMESPACE="gpu-pool"
SERVICE_NAME="gpu-pool-webhook"
SECRET_NAME="gpu-pool-webhook-certs"
WEBHOOK_NAME="gpu-pool-webhook"

echo "🔧 Fixing webhook TLS certificate issue..."

# 기존 webhook 설정 삭제
echo "🗑️  Removing existing webhook configuration..."
kubectl delete mutatingadmissionwebhook ${WEBHOOK_NAME} --ignore-not-found=true

# 기존 secret 삭제
echo "🗑️  Removing existing secret..."
kubectl delete secret ${SECRET_NAME} -n ${NAMESPACE} --ignore-not-found=true

# 임시 디렉토리 생성
TMPDIR=$(mktemp -d)
cd $TMPDIR

echo "🔐 Generating new TLS certificates..."

# CA 키 생성
openssl genrsa -out ca.key 2048

# CA 인증서 생성
openssl req -new -x509 -key ca.key -sha256 -subj "/C=KR/ST=Seoul/O=GPU-Pool/CN=gpu-pool-ca" -days 3650 -out ca.crt

# 서버 키 생성
openssl genrsa -out server.key 2048

# 서버 CSR 생성
cat > server.conf <<EOF
[req]
default_bits = 2048
prompt = no
distinguished_name = req_distinguished_name
req_extensions = v3_req

[req_distinguished_name]
C = KR
ST = Seoul
O = GPU-Pool
CN = ${SERVICE_NAME}.${NAMESPACE}.svc

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${SERVICE_NAME}
DNS.2 = ${SERVICE_NAME}.${NAMESPACE}
DNS.3 = ${SERVICE_NAME}.${NAMESPACE}.svc
DNS.4 = ${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local
EOF

openssl req -new -key server.key -out server.csr -config server.conf

# 서버 인증서 생성
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 365 -extensions v3_req -extfile server.conf

echo "📋 Certificate information:"
openssl x509 -in server.crt -text -noout | grep -A 1 "Subject:"

# Kubernetes Secret 생성
echo "🚀 Creating Kubernetes secret..."
kubectl create secret tls ${SECRET_NAME} \
    --cert=server.crt \
    --key=server.key \
    --namespace=${NAMESPACE}

# CA Bundle 추출
CA_BUNDLE=$(cat ca.crt | base64 | tr -d '\n')

echo "📝 Creating webhook configuration with CA Bundle..."

# Webhook 설정 생성
cat > webhook-config-with-ca.yaml <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionWebhook
metadata:
  name: ${WEBHOOK_NAME}
spec:
  webhooks:
  - name: gpu-pool.mrxrunway.ai
    clientConfig:
      service:
        name: ${SERVICE_NAME}
        namespace: ${NAMESPACE}
        path: "/mutate"
      caBundle: ${CA_BUNDLE}
    rules:
    - operations: ["CREATE"]
      apiGroups: [""]
      apiVersions: ["v1"]
      resources: ["pods"]
    admissionReviewVersions: ["v1", "v1beta1"]
    sideEffects: None
    failurePolicy: Fail
    namespaceSelector:
      matchExpressions:
      - key: name
        operator: NotIn
        values: ["kube-system", "gpu-pool"]
EOF

# Webhook 설정 적용
kubectl apply -f webhook-config-with-ca.yaml

echo "✅ Webhook configuration updated with CA Bundle!"
echo ""
echo "🧹 Cleaning up temporary files..."
cd - > /dev/null
rm -rf $TMPDIR

echo "✨ Done! Webhook should now work properly."
echo ""
echo "🧪 Test with: kubectl apply -f test-examples.yaml"
