# syntax=docker/dockerfile:1
# REDnet governance bot — listens for !gov commands in #gov-bot.
FROM python:3.12-alpine
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY bot.py .
CMD ["python3", "-u", "bot.py"]
