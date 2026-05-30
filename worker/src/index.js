// TetherDash relay Worker
// - POST /api/push           : iPhoneアプリが最新stateを送る（writeKeyで認証、端末ごとにDOへ保存）
// - GET  /d/<id>             : ビューワHTML（共有パスワードのBasic認証）
// - GET  /d/<id>/state.json  : 最新state（同上）
//
// 直接の外部到達(CGNAT)が無理なiPhoneの代わりに、ここが公開中継点になる。

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'POST, OPTIONS',
  'access-control-allow-headers': 'authorization, content-type',
};

const json = (status, obj, extra = {}) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { 'content-type': 'application/json', ...extra },
  });

function checkBasicAuth(request, env) {
  const h = request.headers.get('authorization') || '';
  if (!h.startsWith('Basic ')) return false;
  let decoded;
  try { decoded = atob(h.slice(6)); } catch { return false; }
  // "user:pass" のpass部分だけ見る（userは任意）
  const pass = decoded.slice(decoded.indexOf(':') + 1);
  return !!env.VIEW_PASSWORD && pass === env.VIEW_PASSWORD;
}

const authChallenge = () =>
  new Response('Authentication required', {
    status: 401,
    headers: { 'www-authenticate': 'Basic realm="TetherDash"' },
  });

// 配信HTMLの<head>に state.json のURLを差し込む（viewer.htmlは window.STATE_URL を見る）
class InjectState {
  constructor(stateUrl) { this.stateUrl = stateUrl; }
  element(el) {
    el.prepend(
      `<script>window.STATE_URL=${JSON.stringify(this.stateUrl)}</script>`,
      { html: true }
    );
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.split('/').filter(Boolean);

    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS });
    }

    // ---- iPhone → 状態Push ----
    if (request.method === 'POST' && url.pathname === '/api/push') {
      let body;
      try { body = await request.json(); } catch { return json(400, { error: 'bad json' }, CORS); }
      const id = (body.deviceId || '').trim();
      const writeKey = (request.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
      if (!id || !writeKey || !body.state) return json(400, { error: 'missing fields' }, CORS);

      const stub = env.DEVICE.get(env.DEVICE.idFromName(id));
      const r = await stub.fetch('https://do/push', {
        method: 'POST',
        headers: { 'x-write-key': writeKey },
        body: JSON.stringify(body.state),
      });
      return json(r.ok ? 200 : r.status, r.ok ? { ok: true } : { error: 'rejected' }, CORS);
    }

    // ---- 閲覧（/d/<id> 配下、Basic認証必須）----
    if (parts[0] === 'd' && parts[1]) {
      if (!checkBasicAuth(request, env)) return authChallenge();
      const id = parts[1];
      const stub = env.DEVICE.get(env.DEVICE.idFromName(id));

      if (parts[2] === 'state.json') {
        const r = await stub.fetch('https://do/state');
        return new Response(await r.text(), {
          status: r.status,
          headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
        });
      }

      // ビューワHTML（静的アセットを取得しSTATE_URLを注入）
      const asset = await env.ASSETS.fetch(new URL('/viewer.html', request.url));
      return new HTMLRewriter()
        .on('head', new InjectState(`/d/${id}/state.json`))
        .transform(new Response(asset.body, {
          headers: { 'content-type': 'text/html; charset=utf-8' },
        }));
    }

    return new Response('TetherDash relay', { status: 200 });
  },
};

export class DeviceState {
  constructor(state) { this.storage = state.storage; }

  async fetch(request) {
    const url = new URL(request.url);

    if (request.method === 'POST' && url.pathname === '/push') {
      const key = request.headers.get('x-write-key') || '';
      const stored = await this.storage.get('writeKey');
      if (!stored) {
        await this.storage.put('writeKey', key); // 初回Pushで所有権を確定
      } else if (stored !== key) {
        return new Response('forbidden', { status: 403 });
      }
      const bodyText = await request.text();
      await this.storage.put('state', bodyText);
      await this.storage.put('lastSeen', Date.now());
      return new Response('ok');
    }

    if (request.method === 'GET' && url.pathname === '/state') {
      const s = await this.storage.get('state');
      if (!s) return new Response('{"offline":true}', { status: 404 });
      return new Response(s);
    }

    return new Response('not found', { status: 404 });
  }
}
