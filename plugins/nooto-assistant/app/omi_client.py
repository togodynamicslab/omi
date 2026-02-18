import logging

import httpx

from app.config import OMI_API_URL, OMI_APP_ID, OMI_APP_API_KEY

log = logging.getLogger('uvicorn.error')

_http = httpx.AsyncClient(base_url=OMI_API_URL, timeout=15.0)
_headers = {'Authorization': f'Bearer {OMI_APP_API_KEY}', 'Content-Type': 'application/json'}


async def send_notification(uid: str, message: str) -> bool:
    if not OMI_APP_ID or not OMI_APP_API_KEY:
        log.warning(f'Skipping notification (OMI_APP_ID/OMI_APP_API_KEY not set): {message}')
        return False

    try:
        resp = await _http.post(
            f'/v2/integrations/{OMI_APP_ID}/notification',
            params={'uid': uid, 'message': message},
            headers=_headers,
        )
        if resp.status_code < 300:
            log.info(f'[omi] notification sent to {uid}: {message}')
            return True
        log.warning(f'[omi] notification failed ({resp.status_code}): {resp.text}')
    except Exception as e:
        log.error(f'[omi] notification error: {e}')
    return False


async def close():
    await _http.aclose()
