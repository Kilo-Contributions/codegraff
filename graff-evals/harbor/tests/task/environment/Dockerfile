FROM python:3.12-slim-bookworm
RUN useradd --create-home agent && mkdir /app && chown agent:agent /app
# smoke.py copies graff's scripted test model (scripts/eval/mock_model.py) here.
COPY mock_model.py /mock_model.py
COPY script.json /script.json
COPY start.sh /start.sh
WORKDIR /app
USER agent
ENTRYPOINT ["/bin/sh", "/start.sh"]
