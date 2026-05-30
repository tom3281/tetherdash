# TetherDash relay (Cloudflare Worker)

iPhone は CGNAT 内で直接到達できないため、この Worker が公開中継点になる。
アプリが最新stateを Push → 公開URLをパスワード付きで閲覧。

## 構成

- `POST /api/push` — アプリが `{deviceId, state}` を送信（`Authorization: Bearer <writeKey>`）。
  端末ごとの Durable Object に最新stateを保存。writeKey は初回Pushで確定（以後一致必須）。
- `GET /d/<deviceId>` — ビューワHTML。**共有パスワードのBasic認証**。
- `GET /d/<deviceId>/state.json` — 最新state（同認証）。

## デプロイ

```bash
cd worker
npx wrangler secret put VIEW_PASSWORD   # 閲覧パスワードを設定
npx wrangler deploy
```

公開後の閲覧URL: `https://tetherdash.tom3281.workers.dev/d/<deviceId>`
（`<deviceId>` はアプリの「ネット共有」ON時に表示される URL に入っている）

## メモ

- Durable Object は SQLite バックエンド（`new_sqlite_classes`）なので無料プランで動く。
- `public/viewer.html` は `www/remote.html` のコピー。remote.html を更新したら
  `cp www/remote.html worker/public/viewer.html` で同期する。
- アプリ側は `www/index.html` の `CLOUD_BASE` がこの Worker のURLを指している。
