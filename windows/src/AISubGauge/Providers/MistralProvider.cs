using System.Threading;
using System.Threading.Tasks;

namespace AISubGauge.Providers;

public sealed class MistralProvider : IQuotaProvider
{
    public string Id => "mistral";
    public string DisplayName => I18n.Get("windows.provider.mistral");
    public string LogoResource => "WindowsQuotaTray.assets.logos.mistral.png";
    public bool IsSignedInLocally() => false;
    public Task<QuotaSnapshot> FetchAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(QuotaSnapshot.Failure(this, I18n.Get("windows.mistral.usage.only.has.a.console.cookie.endpoint.and.is")));
    }
}
