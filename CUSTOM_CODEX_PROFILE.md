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

## Harbor deployment

`.github/workflows/custom-harbor-deploy.yml` builds `linux/amd64`, pushes an immutable tag to Harbor, and can deploy two hosts sequentially. It intentionally requires a self-hosted runner labelled `cpa-harbor`.

For an HTTP-only Harbor registry, configure the self-hosted runner and both Docker daemons with that registry in `insecure-registries`. HTTP sends registry credentials and image layers without transport encryption. Docker's [insecure registry documentation](https://docs.docker.com/reference/cli/dockerd/#insecure-registries) recommends this mode only for testing, so enable Harbor HTTPS before production automation. A private-network HTTP registry can be used as a temporary migration step only after accepting that risk.

Required repository variables and secrets are listed in the workflow. Use a dedicated Harbor robot account and a restricted deployment SSH key; do not reuse a personal or server-administration key.

Repository variables:

- `HARBOR_REGISTRY`: registry host and optional port, without `http://` or a path.
- `HARBOR_PROJECT`
- `HARBOR_IMAGE_NAME`
- `CPA_DEPLOY_USER`
- `CPA_CANARY_HOST`, `CPA_CANARY_DEPLOY_DIR`, `CPA_CANARY_COMPOSE_FILE`, `CPA_CANARY_HEALTH_URL`
- `CPA_SECONDARY_HOST`, `CPA_SECONDARY_DEPLOY_DIR`, `CPA_SECONDARY_COMPOSE_FILE`, `CPA_SECONDARY_HEALTH_URL`

Repository secrets:

- `HARBOR_USERNAME`
- `HARBOR_PASSWORD`
- `CPA_DEPLOY_SSH_KEY`
- `CPA_SSH_KNOWN_HOSTS`

The workflow does not install a self-hosted runner, change Docker daemon security settings, upload an existing administration key, or create Harbor credentials. Those security-boundary changes must be completed separately before the workflow is enabled.
