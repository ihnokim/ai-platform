#!/bin/bash

# TLS 인증서 생성 스크립트
set -e

NAMESPACE="gpu-pool"
SERVICE_NAME="gpu-pool-webhook"
SECRET_NAME="gpu-pool-webhook-certs"

echo "🔐 Generating TLS certificates for webhook..."

# 임시 디렉토리 생성
TMPDIR=$(mktemp -d)
cd $TMPDIR

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
openssl x509 -in server.crt -text -noout | grep -A 3 "Subject Alternative Name"

# Kubernetes Secret 생성
echo "🚀 Creating Kubernetes secret..."
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret tls ${SECRET_NAME} \
    --cert=server.crt \
    --key=server.key \
    --namespace=${NAMESPACE} \
    --dry-run=client -o yaml | kubectl apply -f -

# CA Bundle을 webhook config에 추가하기 위한 base64 인코딩
CA_BUNDLE=$(cat ca.crt | base64 | tr -d '\n')

echo "✅ Certificates created successfully!"
echo ""
echo "📝 Add this caBundle to your webhook configuration:"
echo "    caBundle: ${CA_BUNDLE}"
echo ""
echo "🧹 Cleaning up temporary files..."
cd - > /dev/null
rm -rf $TMPDIR

echo "✨ Done! You can now deploy the webhook."
