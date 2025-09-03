# Stage 1: Poetry를 사용해 requirements.txt 생성
FROM python:3.13-slim AS builder

WORKDIR /app

# Poetry 설치
RUN pip install --no-cache-dir poetry

# Poetry export 플러그인 설치 (필요한 경우)
RUN poetry self add poetry-plugin-export

# Poetry 의존성 파일 복사
COPY pyproject.toml poetry.lock* ./

# requirements.txt 생성
RUN poetry export -f requirements.txt --output requirements.txt --without-hashes --only=main

# Stage 2: 프로덕션 이미지 (Poetry 없음)
FROM python:3.13-slim AS production

WORKDIR /app

# 이전 stage에서 requirements.txt 복사
COPY --from=builder /app/requirements.txt .

# pip로 의존성 설치 (Poetry 없이)
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

# 애플리케이션 코드 복사
COPY main.py .

# 보안: non-root 사용자 생성
RUN useradd --create-home --shell /bin/bash app \
    && chown -R app:app /app
USER app

# 프로덕션 실행
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
