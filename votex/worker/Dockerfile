FROM python:3.11-slim

WORKDIR /usr/local/app

# Install dependencies
COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source code
COPY app.py ./app.py

ENV PYTHONUNBUFFERED=1

CMD ["python", "app.py"]
