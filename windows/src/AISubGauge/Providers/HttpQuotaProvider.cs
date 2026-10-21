using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace AISubGauge.Providers;

// Shared transport for the four HTTP providers; endpoints are fixed by each implementation.
public abstract class HttpQuotaProvider : IQuotaProvider
{
    public abstract string Id { get; }
    public abstract string DisplayName { get; }
    public abstract string LogoResource { get; }
    public abstract bool IsSignedInLocally();

    public async Task<QuotaSnapshot> FetchAsync(CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false };
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
            QuotaSnapshot snapshot = await FetchCoreAsync(client, timeout.Token).ConfigureAwait(false);
            if (snapshot.Windows.Count == 0 || snapshot.RemainingPercent is null)
                throw new QuotaReadException(DisplayName + I18n.Get("windows.returned.no.usable.quota.windows"));
            return snapshot;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (OperationCanceledException) { return QuotaSnapshot.Failure(this, DisplayName + I18n.Get("windows.quota.read.timed.out.20.seconds")); }
        catch (QuotaReadException error) { return QuotaSnapshot.Failure(this, error.Message); }
        catch (JsonException) { return QuotaSnapshot.Failure(this, DisplayName + I18n.Get("windows.credential.or.quota.data.has.an.invalid.format")); }
        catch (HttpRequestException) { return QuotaSnapshot.Failure(this, DisplayName + I18n.Get("windows.official.quota.service.connection.failed")); }
        catch (Exception) { return QuotaSnapshot.Failure(this, DisplayName + I18n.Get("windows.credential.read.or.quota.request.failed")); }
    }

    protected abstract Task<QuotaSnapshot> FetchCoreAsync(HttpClient client, CancellationToken cancellationToken);

    protected static string? EnvironmentToken(params string[] names)
    {
        foreach (string name in names)
        {
            string? value = Environment.GetEnvironmentVariable(name);
            if (!string.IsNullOrWhiteSpace(value))
                return value.Trim();
        }
        return null;
    }

    protected static Task<JsonDocument> ReadCredentialAsync(string path, CancellationToken cancellationToken) =>
        CredentialFiles.ReadAsync(path, cancellationToken);

    protected static HttpRequestMessage Request(HttpMethod method, string endpoint, string token, object? body = null)
    {
        var request = new HttpRequestMessage(method, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
        if (body is not null)
            request.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        return request;
    }

    protected static async Task<JsonDocument> SendAsync(HttpClient client, HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Uri? endpoint = request.RequestUri;
        using HttpResponseMessage response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        if (response.RequestMessage?.RequestUri != endpoint)
            throw new QuotaReadException(I18n.Get("windows.the.official.quota.service.returned.an.unexpected.address"));
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new QuotaReadException(I18n.Get("windows.the.official.service.rejected.credentials.sign.in.again.in.the"));
        if (!response.IsSuccessStatusCode)
            throw new QuotaReadException(I18n.Get("windows.the.official.quota.service.returned.an.error.or.redirect"));
        using Stream stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        byte[] bytes = await GrokProvider.ReadBoundedAsync(stream, 1_048_576, cancellationToken).ConfigureAwait(false);
        return JsonDocument.Parse(bytes);
    }
}
