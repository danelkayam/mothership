FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

RUN pip install --no-cache-dir uv

COPY pyproject.toml /app/pyproject.toml
RUN uv sync --no-dev --no-install-project

COPY air_station_fetcher.py /app/air_station_fetcher.py
RUN uv sync --no-dev

CMD ["sleep", "infinity"]