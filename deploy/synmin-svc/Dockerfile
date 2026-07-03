# syntax=docker/dockerfile:1
# REDnet synmin service — isolates the Synapse-admin credential behind three
# read/purge operations. Stdlib only, no pip install: the smaller this powerful
# surface, the better. Parallels mint-svc (which isolates MAS admin).
FROM python:3.12-alpine
WORKDIR /app
COPY synmin_svc.py .
# non-root
RUN adduser -D -H synminsvc
USER synminsvc
EXPOSE 8092
CMD ["python3", "-u", "synmin_svc.py"]
