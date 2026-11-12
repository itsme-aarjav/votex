FROM python:3.11-slim

RUN apt-get update && \
    apt-get upgrade -y && \
    rm -rf /var/lib/apt/lists/* && \
    pip install --no-cache-dir --upgrade jaraco.context pip setuptools wheel

WORKDIR /usr/local/app

# Install dependencies
COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt && \
    find /usr/local/lib/python3.11/site-packages -name "*.cdx.json" -delete

# Copy application source code
COPY app.py ./app.py

ENV PYTHONUNBUFFERED=1

CMD ["python", "app.py"]
