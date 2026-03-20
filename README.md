# Passkey Login Action

Reusable GitHub Action for Entra passkey authentication whose primary purpose is to return an ESTS cookie for downstream tools. The safest supported design is to keep the passkey signing key in Azure Key Vault, authenticate the workflow to Azure with `azure/login`, and let this action return the cookie as a masked output.

## Security model

This repository now treats security as the primary design goal.

Recommended path:

1. Store the passkey signing key in Azure Key Vault.
2. Use GitHub OIDC with `azure/login` so the workflow does not need a long-lived Azure client secret.
3. Store only passkey metadata in GitHub.
4. The action masks and exports the authenticated ESTS cookie by default because that is its primary purpose.

Less preferred path:

1. Supply `private-key` directly for local testing or tightly controlled scenarios.
2. Do not commit passkey JSON or private keys to the repository.
3. Expect the action to warn when it falls back to a local private key.

## What should be stored where

Suggested GitHub Environment storage:

| Item | Store as | Notes |
| --- | --- | --- |
| `credential-id` | Secret | Authenticator-specific material. |
| `user-handle` | Secret | Authenticator-specific material. |
| `user-principal-name` | Variable or secret | Either works. Use a variable for convenience or a secret if you want all inputs stored the same way. |
| `key-vault-name` | Variable | Configuration only. |
| `key-vault-key-name` | Variable | Configuration only. |
| `key-vault-tenant-id` | Variable | Configuration only. |
| Azure OIDC client ID | Variable | Used by `azure/login`. |
| `private-key` | Secret only if you must use local signing | Common for testing, but less secure than Key Vault. |

## Inputs

Required in all modes:

- `credential-id`
- `user-handle`
- `user-principal-name`

Key Vault mode, recommended:

- `key-vault-name`
- `key-vault-key-name`
- `key-vault-tenant-id` optional
- `key-vault-access-token` optional
- `key-vault-client-id` optional fallback
- `key-vault-client-secret` optional fallback

Local key mode, fallback:

- `private-key`

Optional behavior:

- `auth-url`
- `proxy`
- `export-auth-cookie` default `true`

## Outputs

- `authenticated`
- `cookie-name`
- `user-principal-name`
- `signature-method`
- `key-vault-name`
- `auth-cookie` populated by default unless `export-auth-cookie: false`

`auth-cookie` is masked before being written as an output, but it is still sensitive session material. The action prefers `ESTSAUTH` when available because that is the default cookie this action is intended to return.

## Recommended workflow

This is the default model the action is designed for.

```yaml
name: Passkey Login

on:
  workflow_dispatch:

permissions:
  contents: read
  id-token: write

jobs:
  passkey-login:
    runs-on: windows-latest
    environment: entra-prod

    steps:
      - uses: actions/checkout@v4

      - name: Azure login via OIDC
        uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.KEY_VAULT_TENANT_ID }}
          allow-no-subscriptions: true

      - name: Passkey login
        id: passkey
        uses: nathanmcnulty/action-passkey-login@v1
        with:
          credential-id: ${{ secrets.PASSKEY_CREDENTIAL_ID }}
          user-handle: ${{ secrets.PASSKEY_USER_HANDLE }}
          user-principal-name: ${{ secrets.PASSKEY_USER_PRINCIPAL_NAME || vars.PASSKEY_USER_PRINCIPAL_NAME }}
          key-vault-name: ${{ vars.PASSKEY_KEY_VAULT_NAME }}
          key-vault-key-name: ${{ vars.PASSKEY_KEY_VAULT_KEY_NAME }}
          key-vault-tenant-id: ${{ vars.KEY_VAULT_TENANT_ID }}

      - name: Use login result
        shell: pwsh
        env:
          ESTS_COOKIE: ${{ steps.passkey.outputs.auth-cookie }}
        run: |
          if ('${{ steps.passkey.outputs.authenticated }}' -ne 'true') {
            throw 'Passkey authentication did not complete successfully.'
          }

          "Authenticated user: ${{ steps.passkey.outputs.user-principal-name }}"
          "Signature method: ${{ steps.passkey.outputs.signature-method }}"
          "Cookie type: ${{ steps.passkey.outputs.cookie-name }}"

          if ([string]::IsNullOrWhiteSpace($env:ESTS_COOKIE)) {
            throw 'Expected auth-cookie output to be present.'
          }
```

## Using the ESTS cookie downstream

The action exports the ESTS cookie by default because that is the main artifact it produces. If you want to disable that output, set `export-auth-cookie: false`.

Example using the cookie with a downstream PowerShell flow like `Connect-XdrByEstsCookie`:

```yaml
      - name: Passkey login
        id: passkey
        uses: nathanmcnulty/action-passkey-login@v1
        with:
          credential-id: ${{ secrets.PASSKEY_CREDENTIAL_ID }}
          user-handle: ${{ secrets.PASSKEY_USER_HANDLE }}
          user-principal-name: ${{ secrets.PASSKEY_USER_PRINCIPAL_NAME || vars.PASSKEY_USER_PRINCIPAL_NAME }}
          key-vault-name: ${{ vars.PASSKEY_KEY_VAULT_NAME }}
          key-vault-key-name: ${{ vars.PASSKEY_KEY_VAULT_KEY_NAME }}

      - name: Downstream use of cookie
        shell: pwsh
        env:
          ESTS_COOKIE: ${{ steps.passkey.outputs.auth-cookie }}
        run: |
          if ([string]::IsNullOrWhiteSpace($env:ESTS_COOKIE)) {
            throw 'Expected auth-cookie output to be present.'
          }

          $secureCookie = ConvertTo-SecureString $env:ESTS_COOKIE -AsPlainText -Force
          # Connect-XdrByEstsCookie -SecureEstsAuthCookieValue $secureCookie
```

Do not print the cookie. Do not promote it to an artifact. Keep its use scoped to the smallest possible set of steps.

## Local key mode

This is expected to be common during early testing or read-only automation, but it is still less secure than Key Vault-backed signing.

```yaml
      - name: Passkey login with local key
        uses: nathanmcnulty/action-passkey-login@v1
        with:
          credential-id: ${{ secrets.PASSKEY_CREDENTIAL_ID }}
          user-handle: ${{ secrets.PASSKEY_USER_HANDLE }}
          user-principal-name: ${{ secrets.PASSKEY_USER_PRINCIPAL_NAME || vars.PASSKEY_USER_PRINCIPAL_NAME }}
          private-key: ${{ secrets.PASSKEY_PRIVATE_KEY }}
```

If both a complete Key Vault configuration and `private-key` are provided, the action uses Key Vault and ignores the private key.

## Private repo testing

The repository does not need to be public for testing.

You can test this action in the same private repository by using a local path reference:

```yaml
      - name: Passkey login from same repo
        id: passkey
        uses: ./
        with:
          credential-id: ${{ secrets.PASSKEY_CREDENTIAL_ID }}
          user-handle: ${{ secrets.PASSKEY_USER_HANDLE }}
          user-principal-name: ${{ secrets.PASSKEY_USER_PRINCIPAL_NAME || vars.PASSKEY_USER_PRINCIPAL_NAME }}
          private-key: ${{ secrets.PASSKEY_PRIVATE_KEY }}
```

That is the simplest way to validate the action before making the repository public. Once you want other repositories to consume it, publish a tag such as `v1` and reference `owner/action-passkey-login@v1`.

## Local script testing

For local testing outside GitHub Actions, the included script still supports a passkey JSON file:

```powershell
./PasskeyLogin.ps1 -KeyFilePath ./secadmin.passkey -PassThru
```

The script no longer writes token previews to the console. It only includes the authenticated cookie value in its returned object when `-IncludeAuthenticationCookie` is specified.

## Notes

- The action bundles `PasskeyLogin.ps1` and runs it with PowerShell 7.
- The action masks sensitive inputs before invoking the script.
- `azure/login` should run before this action when using Key Vault-backed signing.
- If you grant Key Vault data-plane access, use a role or permission set that allows signing but no broader secret access than necessary.

## Publishing

Tag a release such as `v1.0.0` and publish through the GitHub Marketplace flow in repository settings.
