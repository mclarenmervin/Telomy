from fastapi import FastAPI
from app.common.logging_config import configure_logging
from app.gateway.webhooks import router as webhooks_router

configure_logging()
app = FastAPI(title="healthagent-gateway")
app.include_router(webhooks_router)


@app.get("/health")
def health():
    return {"status": "ok"}
