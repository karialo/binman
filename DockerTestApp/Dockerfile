FROM python:3.11-slim
WORKDIR /app
COPY . .
RUN if [ -f requirements.txt ]; then pip install --no-cache-dir -r requirements.txt; \
    elif [ -f pyproject.toml ]; then pip install --no-cache-dir .; \
    fi
CMD ["bash", "-lc", "/home/kari/.local/share/binman/apps/DockerTestApp/bin/DockerTestApp"]
