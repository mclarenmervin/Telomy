from fastapi import FastAPI
from app.common.logging_config import configure_logging
from app.gateway.activity_webhooks import router as activity_router
from app.gateway.api.admin import router as admin_router
from app.gateway.api.accounts import care_router, router as accounts_router
from app.gateway.api.admin_people import router as admin_people_router
from app.gateway.api.admin_centre_operations import router as admin_centre_operations_router
from app.gateway.api.centre import router as centre_router
from app.gateway.api.doctor import router as doctor_router
from app.gateway.api.chat import router as chat_router
from app.gateway.api.correlations import router as correlations_router
from app.gateway.api.environment import router as environment_router
from app.gateway.api.genetics import router as genetics_api_router
from app.gateway.api.labs import router as labs_router
from app.gateway.api.scores import router as scores_router
from app.gateway.api.therapies import router as therapies_router
from app.gateway.api.therapy_sessions import router as therapy_sessions_router
from app.gateway.genetic_webhooks import router as genetic_router
from app.gateway.lab_webhooks import router as lab_router
from app.gateway.webhooks import router as webhooks_router

configure_logging()
app = FastAPI(title="healthagent-gateway")
app.include_router(webhooks_router)
app.include_router(activity_router)
app.include_router(lab_router)
app.include_router(genetic_router)
app.include_router(labs_router)
app.include_router(scores_router)
app.include_router(chat_router)
app.include_router(correlations_router)
app.include_router(therapies_router)
app.include_router(therapy_sessions_router)
app.include_router(environment_router)
app.include_router(genetics_api_router)
app.include_router(admin_router)
app.include_router(accounts_router)
app.include_router(care_router)
app.include_router(admin_people_router)
app.include_router(admin_centre_operations_router)
app.include_router(centre_router)
app.include_router(doctor_router)


@app.get("/health")
def health():
    return {"status": "ok"}
