# syntax=docker/dockerfile:1
# REDnet governance bot — listens for !gov commands in #gov-bot, and serves the
# in-client invite minting endpoint (mint_endpoint.py).
FROM python:3.12-alpine
WORKDIR /app
# qrencode: render-invite-card.py (mounted at /app) shells it to build invite QRs.
RUN apk add --no-cache libqrencode-tools
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY bot.py community.py mint_endpoint.py .
CMD ["python3", "-u", "bot.py"]
