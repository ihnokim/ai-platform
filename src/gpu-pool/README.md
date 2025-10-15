# GPU Pool Mutating Webhook

간단한 Mutating Admission Webhook 예제입니다. Pod 생성 시 특정 annotation이 있으면 자동으로 label을 추가합니다.

## 🎯 기능

- Pod에 `inho: message` annotation이 있으면 `inho: hello` label을 자동 추가
- 기존 labels가 있어도 안전하게 추가
- 시스템 네임스페이스는 제외

## 🚀 빠른 시작

### 1. 이미지 빌드
```bash
make build
```

### 2. TLS 인증서 생성
```bash
make generate-certs
```

### 3. Webhook 배포
```bash
make deploy
```

### 4. Webhook 설정 배포 (caBundle 추가 후)
```bash
# generate-certs.sh 실행 후 출력된 caBundle을 webhook-config.yaml에 추가
make deploy-config
```

### 5. 테스트
```bash
# 테스트 Pod 생성
make test

# 결과 확인
make check-test
```

## 📁 파일 구조

```
manifests/gpu-pool/
├── main.go              # 웹훅 서버 메인
├── webhook.go           # 웹훅 로직
├── go.mod              # Go 모듈
├── Dockerfile          # 컨테이너 이미지
├── deployment.yaml     # Kubernetes 배포
├── webhook-config.yaml # 웹훅 설정
├── generate-certs.sh   # TLS 인증서 생성
├── test-examples.yaml  # 테스트 예제
├── Makefile           # 빌드/배포 자동화
└── README.md          # 이 파일
```

## 🧪 테스트 시나리오

1. **annotation `inho: message` 있음** → label `inho: hello` 추가됨
2. **annotation 없음** → 변경 없음
3. **annotation `inho: wrong-value`** → 변경 없음
4. **기존 labels + annotation `inho: message`** → label `inho: hello` 추가됨

## 🔧 개발

### 로컬 개발 (Kind 사용)
```bash
# Kind 클러스터에 이미지 로드하며 빌드
make dev-build

# 전체 개발 환경 배포
make dev-deploy
```

### 로그 확인
```bash
make logs
```

### 상태 확인
```bash
make status
```

### 정리
```bash
# 테스트 Pod만 삭제
make clean-test

# 모든 리소스 삭제
make clean
```

## 📋 Webhook 동작 과정

1. **Pod 생성 요청** → Kubernetes API Server
2. **Admission Controller** → Webhook 호출
3. **Webhook 검사** → annotation `inho: message` 확인
4. **JSON Patch 생성** → label `inho: hello` 추가
5. **수정된 Pod** → 클러스터에 생성

## 🔐 TLS 인증서

Webhook은 HTTPS 통신이 필수입니다:

- `generate-certs.sh`로 자체 서명 인증서 생성
- CA Bundle을 `webhook-config.yaml`에 추가 필요
- 인증서는 Kubernetes Secret으로 저장

## ⚠️ 주의사항

- `failurePolicy: Ignore`로 설정하여 Webhook 실패 시에도 Pod 생성 허용
- 시스템 네임스페이스(`kube-system`, `kube-public`, `gpu-pool`)는 제외
- Webhook 자체 Pod는 무한 루프 방지를 위해 제외

## 🎨 커스터마이징

`webhook.go`의 `mutatePod` 함수를 수정하여 다른 로직 구현 가능:

```go
// 예: 다른 annotation/label 조합
if pod.Annotations != nil && pod.Annotations["custom"] == "value" {
    // 커스텀 로직
}
```
