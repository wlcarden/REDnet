# syntax=docker/dockerfile:1
# REDnet mint service — isolates the MAS-admin credential behind one operation.
# Stdlib only, no pip install: the smaller this powerful surface, the better.
FROM python:3.12-alpine
WORKDIR /app
COPY mint_svc.py .
# non-root
RUN adduser -D -H mintsvc
USER mintsvc
EXPOSE 8090
CMD ["python3", "-u", "mint_svc.py"]
