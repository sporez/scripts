import os

import httpx
from fastapi import FastAPI, Query, Response
from fastapi.responses import JSONResponse

app = FastAPI()

API_KEY = os.environ["FETCH_PROXY_API_KEY"]

BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
    "DNT": "1",
    "Connection": "keep-alive",
    "Upgrade-Insecure-Requests": "1",
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Sec-Fetch-User": "?1",
    "Sec-CH-UA": '"Chromium";v="131", "Not_A Brand";v="24"',
    "Sec-CH-UA-Mobile": "?0",
    "Sec-CH-UA-Platform": '"Linux"',
}


@app.get("/fetch")
async def fetch(url: str = Query(...), key: str = Query(...)):
    if key != API_KEY:
        return JSONResponse(status_code=401, content={"error": "invalid api key"})

    try:
        async with httpx.AsyncClient(follow_redirects=True, timeout=30) as client:
            resp = await client.get(url, headers=BROWSER_HEADERS)
    except httpx.RequestError as e:
        return JSONResponse(status_code=502, content={"error": str(e)})

    content_type = resp.headers.get("content-type", "text/html")
    is_text = any(t in content_type for t in ("text/", "json", "xml", "javascript"))

    if is_text:
        return Response(content=resp.text, status_code=resp.status_code, media_type=content_type)
    return Response(content=resp.content, status_code=resp.status_code, media_type=content_type)
