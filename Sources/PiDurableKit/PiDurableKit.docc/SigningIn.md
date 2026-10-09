# Signing In

Use a Claude, ChatGPT, GitHub Copilot, or OpenRouter subscription instead of an API key.

## Overview

Providers with an OAuth sign-in report it in ``ProviderInfo/oauth``. ``Models/login(to:interaction:installationID:agentName:)``
runs pi-ai's sign-in flow: the provider's page opens in an `ASWebAuthenticationSession`, its redirect reaches a loopback
server inside the app, and the tokens are stored in ``Models/credentials`` and refreshed automatically.

```swift
let models = Models(credentials: .keychain)
try await models.login(to: .anthropic, interaction: .webAuthenticationSession())
```

Third-party use of subscriptions may be billed differently from first-party apps; check with each provider.
