# Custom Codex Request Profile

This fork keeps the Codex request identity aligned with the owner's macOS Codex Desktop installation while leaving request-body timezone and language rewriting in the separate `codex-ny-tz-plugin`.

## Baseline

- Upstream repository: `router-for-me/CLIProxyAPI`
- Initial upstream commit: `a270e7b9e57aaecd8f82555f44c2108518ad2330`
- uTLS version: `v1.8.2`
- Plugin repository: `xionghaizhi/codex-ny-tz-plugin`

## Target profile

| Layer | Target | Owner |
| --- | --- | --- |
| `User-Agent` | `Codex/0.159.0 (Mac OS 15.8.0; arm64) unknown (Codex Desktop; 26.928.20755)` | This fork |
| `Originator` | `Codex` | This fork |
| ChatGPT TLS ClientHello | `utls.HelloSafari_Auto` | This fork |
| HTTP protocol | HTTP/2 when negotiated by the Safari profile | This fork |
| Body timezone | `Asia/Singapore` | Plugin |
| Existing `Accept-Language` | Replace with `en-US,en;q=0.9`; do not add when absent | Plugin |

The HTTP identity values were derived from the owner's Codex Desktop installation after removing a local `http_headers` override. The Safari ClientHello is an intentional built-in uTLS profile, not an exact reproduction of the captured TLS 1.2 ClientHello. In uTLS `v1.8.2`, `HelloSafari_Auto` resolves to Safari 16.0 and offers `h2` followed by `http/1.1` through ALPN.

## Source locations and ordering

### HTTP identity

- `internal/runtime/executor/codex_executor_request.go`
  - `codexUserAgent`
  - `codexOriginator`
  - `applyFinalCodexIdentityHeaders`
- `internal/registry/models/models.json`
  - Codex free, team, plus, and pro `config.override_header` entries

The model catalog can refresh at startup and every three hours. A refreshed catalog may restore upstream identity values, so each Codex execution path must call `applyFinalCodexIdentityHeaders` after model-level overrides. When `disable-codex-cloaking` is true, model or caller identity overrides remain effective.

The finalizer is used by standard Responses, streaming Responses, compact Responses, image requests, and WebSocket request preparation. Keep it after `applyCodexRoutingHint` and before the request is logged or sent.

### TLS transport

- `internal/runtime/executor/helps/utls_client.go`
  - `chatGPTClientHelloID`
  - `utlsRoundTripper.createConnection`
  - `fallbackRoundTripper.RoundTrip`
  - `NewUtlsHTTPClient`

The Safari profile is selected only for HTTPS requests whose hostname is exactly `chatgpt.com`. Custom Codex base URLs continue to use the standard fallback transport. The Codex WebSocket dialer uses its own standard TLS path and is not changed by this uTLS setting.

### Plugin boundary

The native plugin owns only request data:

- Rewrite `<timezone>` and `<current_date>` using `Asia/Singapore`.
- Replace `Accept-Language` only when the incoming request already contains it.

The plugin cannot change the TCP/TLS ClientHello. Existing deployments mount the plugin directory into `/CLIProxyAPI/plugins`, so upgrading the CPA image does not replace the plugin binary.

## Upgrade checklist

1. Fetch `upstream/main` and record the new upstream commit or release tag.
2. Merge the upstream change into the custom branch without overwriting unrelated local work.
3. Confirm the four target identity values in the table above are still current.
4. Recheck every call to `applyModelHeaderOverrides`; a Codex send path must finalize the custom identity afterwards.
5. Recheck `NewUtlsHTTPClient` and the exact-host `chatgpt.com` routing condition.
6. Confirm the pinned uTLS version still maps `HelloSafari_Auto` to an HTTP/2-capable profile.
7. Run:

   ```bash
   go test ./internal/runtime/executor/... ./internal/registry/...
   go build -o test-output ./cmd/server && rm test-output
   bash .github/scripts/deploy-custom-image_test.sh
   ```

8. Build an immutable image tag and deploy one server first.
9. Verify health, plugin loading, final logged headers, and a real Codex Responses request before deploying the second server.
10. Record the deployed image digest and keep the previous image tag for rollback.

## CNB image publishing and deployment

Images are published only to `docker.cnb.cool/product-warehouse/docker/cliproxyapi`. Docker repository names must be lowercase, so the display name `CLIProxyAPI` cannot be used as the repository path.

- `.github/workflows/docker-image.yml` publishes multi-architecture images when a `v*` tag is pushed.
- `.github/workflows/custom-cnb-deploy.yml` manually builds `linux/amd64`, pushes an immutable tag, and can deploy two hosts sequentially.

CNB documents the registry username as the fixed lowercase value `cnb`. Store a CNB access token with `registry-package:rw` permission as the GitHub Actions repository secret `CNB_TOKEN`; never commit it. See the [CNB Docker registry documentation](https://docs.cnb.cool/zh/artifact/docker.html).

Use a restricted deployment SSH key; do not reuse a personal or server-administration key.

Repository variables:

- `CPA_DEPLOY_USER`
- `CPA_CANARY_HOST`, `CPA_CANARY_DEPLOY_DIR`, `CPA_CANARY_COMPOSE_FILE`, `CPA_CANARY_HEALTH_URL`
- `CPA_SECONDARY_HOST`, `CPA_SECONDARY_DEPLOY_DIR`, `CPA_SECONDARY_COMPOSE_FILE`, `CPA_SECONDARY_HEALTH_URL`

Repository secrets:

- `CNB_TOKEN`
- `CPA_DEPLOY_SSH_KEY`
- `CPA_SSH_KNOWN_HOSTS`

The workflow does not upload an existing administration key or create a CNB access token. Those security-boundary changes must be completed separately before deployment is enabled.
