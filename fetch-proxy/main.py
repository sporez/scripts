import os

import httpx
from fastapi import FastAPI, Query, Response
from fastapi.responses import JSONResponse

app = FastAPI()

API_KEY = os.environ["FETCH_PROXY_API_KEY"]

USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)


@app.get("/fetch")
async def fetch(url: str = Query(...), key: str = Query(...)):
    if key != API_KEY:
        return JSONResponse(status_code=401, content={"error": "invalid api key"})

    try:
        async with httpx.AsyncClient(follow_redirects=True, timeout=30) as client:
            resp = await client.get(url, headers={"User-Agent": USER_AGENT})
    except httpx.RequestError as e:
        return JSONResponse(status_code=502, content={"error": str(e)})

    content_type = resp.headers.get("content-type", "text/html")
    return Response(content=resp.content, status_code=resp.status_code, media_type=content_type)
