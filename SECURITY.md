# Security Policy / 安全策略

## 支持的版本 / Supported versions

本项目处于活跃开发期（当前版本 `0.4.1+8`），仅维护最新版本。请始终使用最新 release。

This project is under active development (current version `0.4.1+8`). Only the latest version is supported — always use the latest release.

## 报告漏洞 / Reporting a vulnerability

请**不要**在公开 issue 中提交安全漏洞，改为通过 GitHub 私有安全通告上报：

1. 打开仓库页面 → **Security** 标签页 → **Report a vulnerability**（或直接访问 `https://github.com/ijkzen/zcoder/security/advisories/new`）。
2. 尽量包含：影响范围、复现步骤、受影响的版本、你观察到的危害，以及（如有）修复建议。

Please **do not** report vulnerabilities in public issues. Use GitHub's private security advisory instead:

1. Open the **Security** tab on the repo → **Report a vulnerability** (or go directly to `https://github.com/ijkzen/zcoder/security/advisories/new`).
2. Include: scope, reproduction steps, affected versions, observed impact, and a suggested fix if you have one.

我们会在 48 小时内确认收到，评估后尽快修复，并通过安全通告（披露期默认 90 天）发布细节。

We will acknowledge receipt within 48 hours, fix as soon as possible, and publish details via a security advisory (default disclosure window: 90 days).

## 本项目相关的安全说明 / Security notes for this project

- **配对凭据即远程控制权限**：扫描桌面端二维码获得的 `sid + hash` 足以远程读取会话内容、下发命令。请勿公开分享配对二维码或凭据截图；本应用不会上传或传输这些凭据到除中继服务（`wss://zcode.z.ai/ws`）以外的任何地方。
- **本地存储**：配对凭据与会话纯文本缓存在本地 sqflite 数据库中，未加密。设备丢失/共用时应视为凭据泄露，可回到桌面端清除配对。
- 协议认证基于 `HMAC-SHA256`（详见 `docs/protocol/01-relay-transport.md` 与 `docs/adr/0001-…`）。发现任何认证/授权绕过、中间人（TLS 校验缺失）或凭据泄露问题，请按上述渠道优先上报。

- **Pairing credentials grant remote control**: the `sid + hash` obtained by scanning the desktop QR code are sufficient to read conversation content and issue commands remotely. Never share pairing QR codes or credential screenshots. This app never uploads credentials anywhere except the relay service (`wss://zcode.z.ai/ws`).
- **Local storage**: pairing credentials and plaintext conversation caches live in a local sqflite database, unencrypted. Treat a lost/shared device as credential leakage and clear the pairing from the desktop app.
- Protocol auth is based on `HMAC-SHA256` (see `docs/protocol/01-relay-transport.md` and `docs/adr/0001-…`). Report any auth/authorization bypass, TLS-validation gaps (MITM), or credential leakage through the private channel above.
