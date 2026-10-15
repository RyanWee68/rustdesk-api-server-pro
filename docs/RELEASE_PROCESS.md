# Release Process

Use the original tag-based workflow for binary releases and the manual Docker build check:

- `.github/workflows/build-release.yml`
- `.github/workflows/ghcr-docker.yml`

Do not create one-off release workflows unless absolutely necessary.

## Docker Delivery

Docker images are not published to GitHub/GHCR. `.github/workflows/ghcr-docker.yml` is a manual build-only check with `push: false`; it does not log in to a registry, change `VERSION`, or push tags. The self-hosted deployment target is `192.168.0.211`, where images are built, tested, and deployed locally.

## Standard Release Steps (tag-based)

1. Ensure `main` is clean and all intended changes are merged.
2. Confirm the `VERSION` file reflects the desired release version.
3. Confirm compliance files are present:
   - `LICENSE`
   - `NOTICE`
   - `THIRD_PARTY_NOTICES.md`
   - `DISCLAIMER.md`
   - `SECURITY.md`
   - `PRIVACY.md`
   - `COMPLIANCE.md`
   - `CONTRIBUTING.md`
   - `CODE_OF_CONDUCT.md`
   - `SUPPORT.md`
4. Confirm no secrets or runtime data are tracked.
5. Push a semantic tag matching `v*.*.*`.

Example:

```bash
git checkout main
git pull origin main
git tag v1.1.17
git push origin v1.1.17
```

## 手动构建并发布版本包

仓库维护者可在 GitHub Actions 中打开“构建并发布版本”，点击“Run workflow”并填写：

- `tag_name`：发布标签，例如 `v1.3.0`；留空时自动读取 `VERSION`。
- `target_ref`：构建来源，默认 `main`，也可填写明确提交 SHA。
- `release_title`：可选的发布标题；留空时生成标准标题。
- `prerelease`：是否标记为预发布版本。

工作流会先校验标签格式及其与 `VERSION` 的一致性，再执行以下步骤：

1. 针对 Linux、Windows、macOS 构建 amd64 和 arm64 包。
2. 上传六个 ZIP 构建产物。
3. 使用 `.github/RELEASE_TEMPLATE.md` 生成中文发布文案。
4. 创建标签和 GitHub Release，并附加所有 ZIP 文件。

手动发布无需预先创建标签。如果标签或 Release 已存在，重新运行前应先确认目标版本和附件是否允许覆盖。

## Expected Workflows

Tag push should trigger:

- `build-release.yml`: builds Linux, Windows and macOS packages for amd64 and arm64, then uploads zip assets to GitHub Release.
- `ghcr-docker.yml`: optional manual Docker build check; it does not publish an image.

## Do Not Include in Release Assets

- production databases;
- production config files;
- OAuth client secrets;
- SMTP credentials;
- user recordings;
- private logs;
- private keys or certificates.

## If a Release Fails

Prefer fixing the original workflow instead of adding a new one-off workflow.

If a tag or release is partially created:

1. Delete the failed GitHub Release if present.
2. Delete the failed tag both remotely and locally.
3. Fix the workflow or source issue.
4. Re-create the tag.

Example:

```bash
git tag -d v1.1.17 || true
git push origin :refs/tags/v1.1.17 || true
git tag v1.1.17
git push origin v1.1.17
```
