using System;
using System.Collections.Generic;
using AISubGauge.Providers;

namespace AISubGauge;

public static class ProviderRegistry
{
    internal static bool IsSignedInLocally(IQuotaProvider provider)
    {
        // UI/status probes must not crash on unsafe paths. The quota read reports the failure.
        try { return provider.IsSignedInLocally(); }
        catch (Exception) { return false; }
    }

    public static IReadOnlyList<IQuotaProvider> CreateEnabled() => new IQuotaProvider[]
    {
        new CodexProvider(),
        new ClaudeProvider(),
        new GrokProvider(),
        new GeminiProvider(),
        new CopilotProvider(),
        new KimiProvider(),
        new GlmProvider()
    };
}
