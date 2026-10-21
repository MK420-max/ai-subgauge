using System;
using System.Linq;
using System.Threading;
using System.Windows.Forms;
using AISubGauge.Providers;
using AISubGauge.UI;

namespace AISubGauge;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        bool headless = args.Any(arg => arg.ToLowerInvariant() is "--status" or "--running-status" or "--autostart" or "--selftest-grok-refresh" or "--codex-signer");
        if (!AppOptions.TryParse(args, out AppOptions options))
        {
            string error = I18n.Get("windows.invalid.arguments.see.command.line.modes.in.the.readme.export");
            if (headless) StatusReport.WriteError(error);
            else UiMessage.Show(error, I18n.Get("app.name"));
            return 2;
        }
        try
        {
            bool skipSettings = options.Demo || options.Status || options.AutoStartAction is not null || options.CodexSigner ||
                options.RenderPreviewDirectory is not null || options.ScreenshotDirectory is not null ||
                options.PreviewIconsDirectory is not null || options.RunningStatus || options.SelfTestGrok;
            AppSettings? settings = skipSettings ? null : AppSettings.Load();
            I18n.Initialize(options.Language ?? settings?.Language);
            AppTheme.Initialize(options.Theme ?? settings?.Theme);
            if (options.CodexSigner)
            {
                StatusReport.WriteJson(CodexProvider.InspectSigners());
                return 0;
            }
            if (options.RunningStatus)
            {
                StatusReport.WriteJson(new RunningProcesses().Detect());
                return 0;
            }
            if (options.AutoStartAction is string action) return AutoStart.RunCommand(action);
            if (options.SelfTestGrok)
            {
                string path = Environment.GetEnvironmentVariable("AISUBGAUGE_TEST_GROK_CLI") ?? "";
                string mode = Environment.GetEnvironmentVariable("AISUBGAUGE_TEST_GROK_MODE") ?? "success";
                StatusReport.WriteJson(GrokCliRefresh.SelfTestAsync(path, mode).GetAwaiter().GetResult());
                return 0;
            }
            if (options.Status) return StatusReport.SaveAsync(options.StatusFile, options.Demo).GetAwaiter().GetResult();
            ApplicationConfiguration.Initialize();
            if (options.PreviewIconsDirectory is string directory)
            {
                using var logos = new LogoCatalog();
                IconPreviewCapture.Save(directory, logos);
                return 0;
            }
            if (options.RenderPreviewDirectory is string render)
            {
                ScreenshotCapture.RenderPreview(render);
                return 0;
            }
            if (options.ScreenshotDirectory is string screenshots)
            {
                ScreenshotCapture.RenderPreview(screenshots, includeIconSizes: true);
                return 0;
            }
            using var mutex = new Mutex(false, @"Local\AISubGauge");
            bool ownsMutex;
            try { ownsMutex = mutex.WaitOne(0); }
            catch (AbandonedMutexException) { ownsMutex = true; }
            if (!ownsMutex)
            {
                UiMessage.Show(I18n.Get("windows.ai.subgauge.is.already.running"), I18n.Get("app.name"));
                return 1;
            }
            try { return RunApplication(options); }
            finally { mutex.ReleaseMutex(); }
        }
        catch (Exception)
        {
            string message = I18n.Get("windows.operation.failed.check.local.paths.file.and.registry.permissions.output");
            if (headless) StatusReport.WriteError(message);
            else UiMessage.Show(message, I18n.Get("app.name"), MessageBoxButtons.OK);
            return 1;
        }
    }

    private static int RunApplication(AppOptions options)
    {
        using var context = new TrayApplicationContext(options);
        Application.Run(context);
        return context.ExitCode;
    }
}

internal sealed record AppOptions(bool Demo, string? ScreenshotDirectory, string? PreviewIconsDirectory, bool Status,
    string? StatusFile, string? AutoStartAction, bool SelfTestGrok, string? RenderPreviewDirectory,
    bool RunningStatus = false, string? Language = null, string? Theme = null, bool CodexSigner = false)
{
    public static bool TryParse(string[] args, out AppOptions options)
    {
        bool demo = false, status = false, runningStatus = false, selfTest = false, codexSigner = false, valid = true;
        string? screenshot = null, preview = null, statusFile = null, autostart = null, render = null, language = null, theme = null;
        int modes = 0;
        for (int index = 0; index < args.Length; index++)
        {
            string argument = args[index].ToLowerInvariant();
            if (argument == "--demo") { demo = true; continue; }
            if (argument == "--lang")
            {
                if (language is not null || ++index >= args.Length || args[index] is not ("en" or "zh-Hans"))
                { valid = false; break; }
                language = args[index];
                continue;
            }
            if (argument == "--theme")
            {
                if (theme is not null || ++index >= args.Length || args[index] is not ("light" or "dark"))
                { valid = false; break; }
                theme = args[index];
                continue;
            }
            if (modes++ != 0) { valid = false; break; }
            if (argument == "--running-status") { runningStatus = true; continue; }
            if (argument == "--codex-signer") { codexSigner = true; continue; }
            if (argument == "--selftest-grok-refresh") { selfTest = true; continue; }
            if (argument == "--status")
            {
                status = true;
                if (index + 1 < args.Length && !args[index + 1].StartsWith("--", StringComparison.Ordinal)) statusFile = args[++index];
                continue;
            }
            if (argument is not ("--screenshot" or "--preview-icons" or "--render-preview" or "--autostart") ||
                ++index >= args.Length || string.IsNullOrWhiteSpace(args[index]) || args[index].StartsWith("--", StringComparison.Ordinal))
            { valid = false; break; }
            string value = args[index];
            switch (argument)
            {
                case "--screenshot": screenshot = value; break;
                case "--preview-icons": preview = value; break;
                case "--render-preview": render = value; break;
                case "--autostart": autostart = value.ToLowerInvariant(); valid = autostart is "on" or "off" or "status"; break;
            }
            if (!valid) break;
        }
        options = new AppOptions(demo, screenshot, preview, status, statusFile, autostart, selfTest, render, runningStatus, language, theme, codexSigner);
        return valid && (statusFile is null || !string.IsNullOrWhiteSpace(statusFile)) &&
            !(demo && (autostart is not null || selfTest || runningStatus || codexSigner));
    }
}
