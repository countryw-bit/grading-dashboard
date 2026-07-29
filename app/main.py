import json
from urllib.parse import quote_plus

import oracledb
from fastapi import FastAPI, Form, Request
from fastapi.encoders import jsonable_encoder
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from app.config import settings
from app.database import (
    fetch_all,
    load_sql,
    oracle_runtime_info,
    test_connection,
)
from app.security import credential_store


app = FastAPI(title=settings.app_name)
app.mount("/static", StaticFiles(directory="app/static"), name="static")

templates = Jinja2Templates(directory="app/templates")

COOKIE_NAME = "grading_session"


def current_session(request: Request):
    return credential_store.get(request.cookies.get(COOKIE_NAME))


def redirect_to_login(message: str | None = None):
    url = "/login"

    if message:
        url += "?message=" + quote_plus(message)

    return RedirectResponse(url=url, status_code=303)


@app.get("/health")
def health():
    runtime = oracle_runtime_info()

    return {
        "status": "ok",
        "environment": settings.app_env,
        "oracle_mode": runtime["driver_mode"],
        "oracle_initialization_error": runtime["initialization_error"],
    }


@app.get("/debug", response_class=HTMLResponse)
def debug_page(request: Request):
    return templates.TemplateResponse(
        request=request,
        name="debug.html",
        context={
            "app_name": settings.app_name,
            "environment": settings.app_env.upper(),
            "runtime": oracle_runtime_info(),
        },
    )


@app.get("/", response_class=HTMLResponse)
def home(request: Request):
    if not current_session(request):
        return RedirectResponse("/login", status_code=303)

    return RedirectResponse("/dashboard", status_code=303)


@app.get("/login", response_class=HTMLResponse)
def login_page(
    request: Request,
    message: str | None = None,
):
    return templates.TemplateResponse(
        request=request,
        name="login.html",
        context={
            "app_name": settings.app_name,
            "environment": settings.app_env.upper(),
            "message": message,
            "runtime": oracle_runtime_info(),
        },
    )


@app.post("/login")
def login(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
):
    username = username.strip()

    try:
        test_connection(username, password)

    except (oracledb.Error, RuntimeError) as exc:
        return templates.TemplateResponse(
            request=request,
            name="login.html",
            context={
                "app_name": settings.app_name,
                "environment": settings.app_env.upper(),
                "message": (
                    "Oracle sign-in failed: "
                    f"{str(exc).splitlines()[0]}"
                ),
                "runtime": oracle_runtime_info(),
            },
            status_code=401,
        )

    token = credential_store.create(
        username=username,
        password=password,
        ttl_minutes=settings.session_ttl_minutes,
    )

    response = RedirectResponse(
        "/dashboard",
        status_code=303,
    )

    response.set_cookie(
        key=COOKIE_NAME,
        value=token,
        httponly=True,
        samesite="strict",
        secure=False,
        max_age=settings.session_ttl_minutes * 60,
    )

    return response


@app.post("/logout")
def logout(request: Request):
    token = request.cookies.get(COOKIE_NAME)

    credential_store.delete(token)

    response = RedirectResponse(
        "/login",
        status_code=303,
    )

    response.delete_cookie(COOKIE_NAME)

    return response


@app.get("/dashboard", response_class=HTMLResponse)
def dashboard(
    request: Request,
    term_code: str | None = None,
):
    session = current_session(request)

    if not session:
        return redirect_to_login(
            "Your local session expired. Please sign in again."
        )

    errors: dict[str, str | None] = {
        "term": None,
        "subterm": None,
        "summary": None,
        "duplicate_roster": None,
        "duplicate_row": None,
    }

    identity = {}

    terms: list[dict] = []
    subterms: list[dict] = []
    sections: list[dict] = []
    duplicate_rosters: list[dict] = []
    duplicate_rows: list[dict] = []

    try:
        identity = test_connection(
            session.username,
            session.password,
        )

        terms = fetch_all(
            session.username,
            session.password,
            load_sql("term_options.sql"),
        )

    except (oracledb.Error, RuntimeError) as exc:
        errors["term"] = str(exc).splitlines()[0]

    if not term_code and terms:
        term_code = terms[0].get("term_code")

    binds = {
        "term_code": term_code.upper() if term_code else None,
    }

    if term_code:
        try:
            subterms = fetch_all(
                session.username,
                session.password,
                load_sql("subterm_options.sql"),
                {
                    "term_code": term_code.upper(),
                },
            )

        except (oracledb.Error, RuntimeError) as exc:
            errors["subterm"] = str(exc).splitlines()[0]

        try:
            sections = fetch_all(
                session.username,
                session.password,
                load_sql("activity_offering_summary.sql"),
                binds,
            )

        except (oracledb.Error, RuntimeError) as exc:
            errors["summary"] = str(exc).splitlines()[0]

        try:
            duplicate_rosters = fetch_all(
                session.username,
                session.password,
                load_sql("duplicate_rosters.sql"),
                binds,
            )

        except (oracledb.Error, RuntimeError) as exc:
            errors["duplicate_roster"] = str(exc).splitlines()[0]

        try:
            duplicate_rows = fetch_all(
                session.username,
                session.password,
                load_sql("duplicate_roster_rows.sql"),
                binds,
            )

        except (oracledb.Error, RuntimeError) as exc:
            errors["duplicate_row"] = str(exc).splitlines()[0]

    duplicate_roster_by_ao: dict[str, int] = {}

    for row in duplicate_rosters:
        ao_id = row.get("activity_offering_id")

        duplicate_roster_by_ao[ao_id] = (
            duplicate_roster_by_ao.get(ao_id, 0)
            + int(row.get("roster_count") or 0)
            - 1
        )

    duplicate_students_by_roster: dict[str, int] = {}

    for row in duplicate_rows:
        roster_id = row.get("roster_id")

        duplicate_students_by_roster[roster_id] = (
            duplicate_students_by_roster.get(roster_id, 0)
            + 1
        )

    for row in sections:
        row["duplicate_roster_count"] = (
            duplicate_roster_by_ao.get(
                row.get("activity_offering_id"),
                0,
            )
        )

        row["duplicate_student_count"] = (
            duplicate_students_by_roster.get(
                row.get("roster_id"),
                0,
            )
        )

    unique_sections = len(
        {
            row.get("activity_offering_id")
            for row in sections
            if row.get("activity_offering_id")
        }
    )

    zero_size = sum(
        1
        for row in sections
        if int(row.get("roster_size") or 0) == 0
    )

    missing_graders = sum(
        1
        for row in sections
        if int(row.get("instructor_count") or 0) == 0
    )

    missing_instructor_emails = sum(
        1
        for row in sections
        if int(row.get("instructors_missing_email") or 0) > 0
    )

    overdue = sum(
        1
        for row in sections
        if (
            row.get("is_overdue") == "Y"
            and row.get("overall_status") != "SUBMITTED"
        )
    )

    totals = {
        "rosters": len(sections),
        "unique_sections": unique_sections,
        "submitted": sum(
            1
            for row in sections
            if row.get("overall_status") == "SUBMITTED"
        ),
        "partial": sum(
            1
            for row in sections
            if row.get("overall_status") == "PARTIAL"
        ),
        "not_started": sum(
            1
            for row in sections
            if row.get("overall_status") == "NOT_STARTED"
        ),
        "duplicate_roster_groups": len(duplicate_rosters),
        "duplicate_roster_excess": sum(
            max(
                int(row.get("roster_count") or 0) - 1,
                0,
            )
            for row in duplicate_rosters
        ),
        "duplicate_students": len(duplicate_rows),
        "duplicate_row_excess": sum(
            max(
                int(row.get("row_count") or 0) - 1,
                0,
            )
            for row in duplicate_rows
        ),
        "zero_size": zero_size,
        "missing_graders": missing_graders,
        "missing_instructor_emails": missing_instructor_emails,
        "overdue": overdue,
    }

    sections_json = json.dumps(
        jsonable_encoder(sections),
        ensure_ascii=False,
    ).replace(
        "</",
        "<" + chr(92) + "/",
    )

    return templates.TemplateResponse(
        request=request,
        name="dashboard.html",
        context={
            "app_name": settings.app_name,
            "environment": settings.app_env.upper(),
            "username": session.username,
            "identity": identity,
            "terms": terms,
            "subterms": subterms,
            "sections": sections,
            "sections_json": sections_json,
            "duplicate_rosters": duplicate_rosters,
            "duplicate_rows": duplicate_rows,
            "totals": totals,
            "selected_term": term_code or "",
            "selected_subterm": "",
            "term_error": errors["term"],
            "subterm_error": errors["subterm"],
            "summary_error": errors["summary"],
            "duplicate_roster_error": errors["duplicate_roster"],
            "duplicate_row_error": errors["duplicate_row"],
        },
    )