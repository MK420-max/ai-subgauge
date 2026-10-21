using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace AISubGauge.Providers;

public sealed class ClaudeProvider : IQuotaProvider
{
    public string Id => "claude";
    public string DisplayName => I18n.Get("provider.claude");
    public string LogoResource => "WindowsQuotaTray.assets.logos.claude.png";

    public bool IsSignedInLocally() =>
        !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("CLAUDE_CODE_OAUTH_TOKEN")) ||
        LocalFiles.Exists(CredentialFiles.ClaudePath);

    public async Task<QuotaSnapshot> FetchAsync(CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            string token = await ReadTokenAsync(timeout.Token).ConfigureAwait(false);
            using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false };
            using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
            using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.anthropic.com/api/oauth/usage");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.Add("anthropic-beta", "oauth-2025-04-20");
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            using HttpResponseMessage response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            if (response.StatusCode == HttpStatusCode.Unauthorized)
                throw new QuotaReadException(I18n.Get("windows.claude.login.credentials.are.invalid.or.expired.401.sign.in"));
            if (response.StatusCode == HttpStatusCode.Forbidden)
                throw new QuotaReadException(I18n.Get("windows.claude.denied.quota.access.403.check.account.permissions"));
            if (!response.IsSuccessStatusCode)
                throw new QuotaReadException(I18n.Get("windows.the.claude.quota.service.returned.an.error.or.redirect"));

            using Stream stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
            byte[] responseBytes = await GrokProvider.ReadBoundedAsync(stream, 1_048_576, timeout.Token).ConfigureAwait(false);
            using JsonDocument document = JsonDocument.Parse(responseBytes);
            var windows = new List<QuotaWindow>();
            foreach ((string key, string title) in new[]
            {
                ("five_hour", I18n.Get("quota.fiveHours")), ("seven_day", I18n.Get("quota.weekly")),
                ("seven_day_opus", I18n.Get("usage.opus.weekly")), ("seven_day_sonnet", I18n.Get("usage.sonnet.weekly"))
            })
            {
                if (!QuotaJson.TryProperty(document.RootElement, key, out JsonElement window) ||
                    !QuotaJson.TryNumber(window, "utilization", out double used))
                    continue;
                windows.Add(new QuotaWindow
                {
                    Id = key,
                    Title = title,
                    RemainingPercent = 100 - used,
                    ResetsAt = QuotaJson.ResetTime(window, "resets_at")
                });
            }
            if (windows.Count == 0)
                throw new QuotaReadException(I18n.Get("windows.claude.returned.no.usable.quota.windows"));
            return new QuotaSnapshot { Provider = this, Plan = I18n.Get("windows.subscription.plan.name.not.provided.by.api"), Windows = windows };
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return QuotaSnapshot.Failure(this, I18n.Get("windows.reading.claude.quota.timed.out.20.seconds"));
        }
        catch (OperationCanceledException) { throw; }
        catch (QuotaReadException error) { return QuotaSnapshot.Failure(this, error.Message); }
        catch (JsonException) { return QuotaSnapshot.Failure(this, I18n.Get("windows.claude.credential.or.quota.data.has.an.invalid.format")); }
        catch (HttpRequestException) { return QuotaSnapshot.Failure(this, I18n.Get("windows.could.not.connect.to.the.claude.quota.service")); }
        catch (Exception) { return QuotaSnapshot.Failure(this, I18n.Get("windows.could.not.read.claude.credentials.or.request.quota")); }
    }

    private static async Task<string> ReadTokenAsync(CancellationToken cancellationToken)
    {
        string? environmentToken = Environment.GetEnvironmentVariable("CLAUDE_CODE_OAUTH_TOKEN");
        if (!string.IsNullOrWhiteSpace(environmentToken))
            return environmentToken.Trim();

        using JsonDocument document = await CredentialFiles.ReadAsync(CredentialFiles.ClaudePath, cancellationToken).ConfigureAwait(false);
        if (QuotaJson.TryProperty(document.RootElement, "claudeAiOauth", out JsonElement oauth))
        {
            string? token = QuotaJson.String(oauth, "accessToken");
            if (!string.IsNullOrWhiteSpace(token))
                return token.Trim();
        }
        throw new QuotaReadException(I18n.Get("windows.the.claude.credential.file.has.no.oauth.accesstoken.sign.in"));
    }
}
