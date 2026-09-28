# Secret Handling Guide

This project can be deployed with OAuth, SMTP, databases, reverse proxies and uploaded recordings. Treat deployment files and runtime data as sensitive.

## Never Commit

Do not commit:

- production `server.yaml`;
- OAuth `clientSecret` values;
- Apple `.p8` private keys used for generating `client_secret` JWT;
- SMTP usernames or passwords;
- database files such as `server.db`, `*.sqlite`, `*.sqlite3`;
- private keys, certificates, `.p12`, `.pfx`, `.pem`, `.key` files;
- logs containing tokens, emails, IP addresses or user identifiers;
- uploaded recordings or user files;
- `.env` files containing real credentials.
- manual API request files containing real passwords, cookies, authorization headers or bearer tokens.

Tracked `.http` / REST client files must stay as templates with placeholders such as `REPLACE_WITH_API_TOKEN`. Put personal runnable copies in ignored files like `*.local.http` or `*.private.http`.

## Safer Configuration Pattern

Keep a sanitized example config in the repository and keep production config outside the repository.

Recommended Docker pattern:

```bash
-v /mnt/docker/rustdesk-api/server.yaml:/app/server.yaml
-v /mnt/docker/rustdesk-api/data:/app/data
```

The host path should be protected with appropriate file permissions and backups.

## Before Sharing Logs

Remove or redact:

- authorization headers;
- cookies;
- OAuth codes and tokens;
- manual API request examples with real bearer tokens or account passwords;
- email addresses;
- public IPs if not necessary;
- user IDs and device IDs;
- database paths and private hostnames where sensitive.

## Before Creating a Release

Run a local check similar to:

```bash
git grep -nE "(BEGIN RSA|BEGIN OPENSSH|AKIA|ghp_|clientSecret|password|private_key|token)" -- .
```

Then manually inspect any matches. Example placeholders in documentation are acceptable; real secrets are not.
