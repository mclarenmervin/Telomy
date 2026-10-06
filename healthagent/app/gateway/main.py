from fastapi import FastAPI
from app.common.logging_config import configure_logging
from app.gateway.activity_webhooks import router as activity_router
from app.gateway.api.scores import router as scores_router
from app.gateway.webhooks import router as webhooks_router

configure_logging()
app = FastAPI(title="healthagent-gateway")
app.include_router(webhooks_router)
app.include_router(activity_router)
app.include_router(scores_router)


@app.get("/health")
def health():
    return {"status": "ok"}
