# Auth Test - JWT Authentication FastAPI App

JWT 토큰 기반 인증을 테스트하는 간단한 FastAPI 애플리케이션입니다.

## 🚀 기능

- **루트 페이지 (`/`)**: JWT 토큰 유무에 따라 로그인 상태 표시
  - 로그인됨: "✅ You are logged in"
  - 로그인 안됨: "❌ You are not logged in" + 로그인 폼
- **로그인 (`/login`)**: 데모용 인증 (username: `demo`, password: `password`)
- **보호된 라우트 (`/protected`)**: JWT 토큰이 필요한 API 엔드포인트
- **헬스체크 (`/health`)**: 애플리케이션 상태 확인

## 🛠️ 로컬 실행

### 1. Poetry 설치 (필요한 경우)
```bash
curl -sSL https://install.python-poetry.org | python3 -
```

### 2. 의존성 설치
```bash
cd src/auth-test
poetry install
```

### 3. 애플리케이션 실행
```bash
# Poetry로 실행
poetry run python main.py
# 또는
poetry run uvicorn main:app --reload
# 또는 스크립트 사용
poetry run start  # 프로덕션 모드
poetry run dev    # 개발 모드 (auto-reload)
```

### 3. 브라우저에서 접속
```
http://localhost:8000
```

## 🐳 Docker 실행

### 1. Docker 이미지 빌드
```bash
docker build -t auth-test .
```

### 2. 컨테이너 실행
```bash
docker run -p 8000:8000 auth-test
```

## 🔧 Kubernetes 배포

### 1. Docker 이미지를 registry에 푸시 (선택사항)
```bash
docker tag auth-test your-registry/auth-test:latest
docker push your-registry/auth-test:latest
```

### 2. Kubernetes 매니페스트 생성 예시
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: auth-test
spec:
  replicas: 2
  selector:
    matchLabels:
      app: auth-test
  template:
    metadata:
      labels:
        app: auth-test
    spec:
      containers:
      - name: auth-test
        image: auth-test:latest
        ports:
        - containerPort: 8000
        env:
        - name: JWT_SECRET_KEY
          value: "your-production-secret-key"
---
apiVersion: v1
kind: Service
metadata:
  name: auth-test-service
spec:
  selector:
    app: auth-test
  ports:
  - port: 80
    targetPort: 8000
  type: ClusterIP
```

## 🔐 인증 정보

- **사용자명**: `demo`
- **비밀번호**: `password`

## 📝 API 엔드포인트

| 엔드포인트 | 메서드 | 설명 | 인증 필요 |
|-----------|--------|------|----------|
| `/` | GET | 메인 페이지 (로그인 상태 표시) | ❌ |
| `/login` | POST | 로그인 (JWT 토큰 발급) | ❌ |
| `/protected` | GET | 보호된 API 엔드포인트 | ✅ |
| `/health` | GET | 헬스체크 | ❌ |

## ⚠️ 주의사항

- 이는 **데모용 애플리케이션**입니다
- 프로덕션 환경에서는:
  - 강력한 JWT_SECRET_KEY 설정
  - 실제 사용자 데이터베이스 연동
  - 비밀번호 해싱 (bcrypt 등)
  - HTTPS 사용
  - 토큰 만료 시간 적절히 설정
