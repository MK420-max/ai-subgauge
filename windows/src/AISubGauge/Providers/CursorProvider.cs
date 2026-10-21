using System.Threading;
using System.Threading.Tasks;

namespace AISubGauge.Providers;

public sealed class CursorProvider : IQuotaProvider
{
    public string Id => "cursor";
    public string DisplayName => I18n.Get("windows.provider.cursor");
    public string LogoResource => "WindowsQuotaTray.assets.logos.cursor.png";
    public bool IsSignedInLocally() => false;
    public Task<QuotaSnapshot> FetchAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(QuotaSnapshot.Failure(this, I18n.Get("windows.cursor.subscription.usage.only.has.a.web.cookie.endpoint.and")));
    }
}
