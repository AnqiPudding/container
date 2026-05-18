#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
from collections.abc import Awaitable, Callable

from aiohttp import ClientError, ClientSession, WSMsgType, web


COMFYUI_BASE = "http://127.0.0.1:8188"
JUPYTER_BASE = "http://127.0.0.1:8889"
HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


def target_url(request: web.Request, upstream: str) -> str:
    url = f"{upstream}{request.path_qs}"
    return url


def request_headers(request: web.Request) -> dict[str, str]:
    return {
        key: value
        for key, value in request.headers.items()
        if key.lower() not in HOP_BY_HOP_HEADERS and key.lower() != "host"
    }


def response_headers(headers: web.BaseRequest.headers) -> dict[str, str]:
    return {
        key: value
        for key, value in headers.items()
        if key.lower() not in HOP_BY_HOP_HEADERS and key.lower() != "content-length"
    }


def is_websocket(request: web.Request) -> bool:
    return request.headers.get("upgrade", "").lower() == "websocket"


async def proxy_websocket(request: web.Request, upstream: str) -> web.WebSocketResponse:
    downstream = web.WebSocketResponse(heartbeat=30)
    await downstream.prepare(request)

    session: ClientSession = request.app["session"]
    try:
        async with session.ws_connect(target_url(request, upstream), headers=request_headers(request), heartbeat=30) as upstream_ws:

            async def downstream_to_upstream() -> None:
                async for msg in downstream:
                    if msg.type == WSMsgType.TEXT:
                        await upstream_ws.send_str(msg.data)
                    elif msg.type == WSMsgType.BINARY:
                        await upstream_ws.send_bytes(msg.data)
                    elif msg.type == WSMsgType.PING:
                        await upstream_ws.ping()
                    elif msg.type == WSMsgType.PONG:
                        await upstream_ws.pong()
                    elif msg.type == WSMsgType.CLOSE:
                        await upstream_ws.close()

            async def upstream_to_downstream() -> None:
                async for msg in upstream_ws:
                    if msg.type == WSMsgType.TEXT:
                        await downstream.send_str(msg.data)
                    elif msg.type == WSMsgType.BINARY:
                        await downstream.send_bytes(msg.data)
                    elif msg.type == WSMsgType.PING:
                        await downstream.ping()
                    elif msg.type == WSMsgType.PONG:
                        await downstream.pong()
                    elif msg.type == WSMsgType.CLOSE:
                        await downstream.close()

            tasks = [
                asyncio.create_task(downstream_to_upstream()),
                asyncio.create_task(upstream_to_downstream()),
            ]
            done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
            for task in done:
                task.result()
    except ClientError:
        if not downstream.closed:
            await downstream.close(message=b"upstream unavailable")

    return downstream


async def proxy_http(request: web.Request, upstream: str) -> web.Response:
    session: ClientSession = request.app["session"]
    body = await request.read()

    try:
        async with session.request(
            request.method,
            target_url(request, upstream),
            headers=request_headers(request),
            data=body,
            allow_redirects=False,
        ) as upstream_response:
            payload = await upstream_response.read()
            headers = response_headers(upstream_response.headers)
            location = headers.get("Location")
            if location:
                headers["Location"] = location.replace(JUPYTER_BASE, "")
            return web.Response(status=upstream_response.status, headers=headers, body=payload)
    except ClientError as exc:
        return web.Response(
            status=503,
            text=f"Workspace service is still starting: {exc}",
            content_type="text/plain",
        )


def handler(upstream: str) -> Callable[[web.Request], Awaitable[web.StreamResponse]]:
    async def _handle(request: web.Request) -> web.StreamResponse:
        if is_websocket(request):
            return await proxy_websocket(request, upstream)
        return await proxy_http(request, upstream)

    return _handle


async def create_session(app: web.Application) -> None:
    app["session"] = ClientSession(auto_decompress=False)


async def close_session(app: web.Application) -> None:
    await app["session"].close()


def make_app() -> web.Application:
    app = web.Application(client_max_size=1024**3)
    app.on_startup.append(create_session)
    app.on_cleanup.append(close_session)
    app.router.add_route("*", "/jupyter", handler(JUPYTER_BASE))
    app.router.add_route("*", "/jupyter/{tail:.*}", handler(JUPYTER_BASE))
    app.router.add_route("*", "/{tail:.*}", handler(COMFYUI_BASE))
    return app


def main() -> None:
    parser = argparse.ArgumentParser(description="Serve ComfyUI and Jupyter from one Modal web port.")
    parser.add_argument("--port", type=int, default=8888)
    args = parser.parse_args()
    web.run_app(make_app(), host="0.0.0.0", port=args.port, access_log=None)


if __name__ == "__main__":
    main()
