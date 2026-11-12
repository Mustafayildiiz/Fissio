FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    OCR_ENGINE=paddleocr \
    OCR_VERSION=PP-OCRv4 \
    OCR_MODEL_VARIANT=mobile \
    OCR_LANG=tr \
    OCR_USE_GPU=false \
    PORT=8080

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

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY ocr ./ocr
COPY app.py ./
COPY tests ./tests

EXPOSE 8080

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]

