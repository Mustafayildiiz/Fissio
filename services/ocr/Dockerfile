FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    OCR_ENGINE=paddleocr \
    OCR_VERSION=PP-OCRv4 \
    OCR_MODEL_VARIANT=mobile \
    OCR_LANG=tr \
    OCR_USE_GPU=false \
    PORT=8080 \
    HOME=/home/app

# System libraries required by PaddlePaddle and OpenCV headless
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    libgl1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt constraints.txt ./
RUN pip install --no-cache-dir -c constraints.txt -r requirements.txt

COPY ocr ./ocr
COPY app.py ./
COPY tests ./tests

# Root olmayan kullanici; model onbellegi (volume) /home/app/.paddleocr altinda
RUN useradd --create-home --uid 10001 app \
    && mkdir -p /home/app/.paddleocr \
    && chown -R app:app /home/app /app
USER app

EXPOSE 8080

# OCR_WORKERS: çıkarım süreç içinde seri (Paddle iş parçacığı güvenli değil); paralellik çoklu süreçle (her biri ~400 MB).
ENV OCR_WORKERS=2
CMD ["sh", "-c", "exec uvicorn app:app --host 0.0.0.0 --port 8080 --workers ${OCR_WORKERS}"]

