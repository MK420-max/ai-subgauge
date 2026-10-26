using AISubGauge.Core;
using AISubGauge.UI;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;

internal static partial class Program
{
    private static ExecutableSignature GrokFixture() => new(SignatureStatus.Valid,
        new X500DistinguishedName("CN=Grok, O=X.AI LLC"),
        ["LEAF", GrokPublisher.IntermediateThumbprint, GrokPublisher.RootThumbprint]);

    private static void AssertNotExpired(Snapshot snapshot, Fault expected)
    {
        Equal(snapshot.Fault, expected);
        Check(!Presentation.SignInExpired(snapshot.Fault));
        Check(!Presentation.CanSignInAgain(snapshot));
        foreach (string language in new[] { "en", "zh-CN" })
        {
            var text = new Texts(language);
            Equal(text.Status(snapshot), text.Error(expected));
            Equal(CodexRowPresentation.PanelStatus(text, snapshot, Clock.Now), text.Error(expected));
            Equal(CodexRowPresentation.SettingsStatus(text, snapshot), text.Error(expected));
        }
    }

    private static void RunGrokHardeningTests()
    {
        var locations = new CliLocations(@"C:\Fixture\Local", @"C:\Fixture\Roaming", @"C:\Fixture\Profile");
        string path = Path.Combine(locations.Profile, ".grok", "bin", "grok.exe");
        Test("Grok accepts only valid exact organization and pinned intermediate/root", () =>
        {
            Check(GrokPublisher.Accepts(GrokFixture()));
            using var executable = new ExecutableResolver(new FakeExecutableFiles(path), new FakeSignatures(GrokFixture()), locations).Resolve("grok");
            Equal(executable.Path, path); Check(!executable.Unsigned);
        });
        var invalid = new[]
        {
            new ExecutableSignature(SignatureStatus.Unsigned),
            GrokFixture() with { Status = SignatureStatus.Invalid },
            GrokFixture() with { Subject = new X500DistinguishedName("O=Other Publisher") },
            GrokFixture() with { Subject = new X500DistinguishedName("O=x.ai llc") },
            GrokFixture() with { Subject = new X500DistinguishedName("CN=\"O=X.AI LLC\"") },
            GrokFixture() with { ChainThumbprints = ["LEAF", "WRONG", GrokPublisher.RootThumbprint] },
            GrokFixture() with { ChainThumbprints = ["LEAF", GrokPublisher.IntermediateThumbprint, "WRONG"] },
            GrokFixture() with { ChainThumbprints = [GrokPublisher.IntermediateThumbprint, GrokPublisher.RootThumbprint] }
        };
        for (int i = 0; i < invalid.Length; i++)
        {
            var signature = invalid[i];
            AsyncTest($"Grok invalid publisher fixture {i} cannot launch even with unsigned npm opt-in", async () =>
            {
                Check(!GrokPublisher.Accepts(signature));
                var files = new FakeExecutableFiles(path);
                var resolver = new ExecutableResolver(files, new FakeSignatures(signature), locations);
                int launches = 0;
                var launcher = new GrokSignIn(() => Task.FromResult(resolver.Resolve("grok", allowUnsignedCodexNpm: true)),
                    _ => { launches++; return Task.CompletedTask; });
                try { await launcher.RunAsync(); throw new InvalidOperationException(); }
                catch (SafeFailure failure)
                {
                    Equal(failure.Fault, Fault.GrokVerificationFailed);
                    foreach (string language in new[] { "en", "zh-CN" })
                        Check(new Texts(language).Error(failure.Fault).Contains("X.AI LLC"));
                }
                Equal(launches, 0); Check(!files.LastLease!.CanRead); Check(!launcher.Running);
            });
        }
        Test("missing Grok CLI has a distinct localized state", () =>
        {
            var signatures = new FakeSignatures(GrokFixture());
            try { using var executable = new ExecutableResolver(new FakeExecutableFiles(), signatures, locations).Resolve("grok"); throw new InvalidOperationException(); }
            catch (SafeFailure failure)
            {
                Equal(failure.Verification!.Status, VerificationStatus.NotFound);
                AssertNotExpired(Snapshot.Failure(Vendor.Grok, failure.Fault, Clock), Fault.GrokCliNotInstalled);
                Equal(new Texts("en").Error(failure.Fault), "Grok CLI not installed");
                Equal(new Texts("zh-CN").Error(failure.Fault), "未安装 Grok CLI");
            }
            Equal(signatures.Calls, 0);
        });
        AsyncTest("expired-token refresh retains underlying fault and offers sign-in; verification stays distinct", async () =>
        {
            foreach (var error in new Exception[]
            {
                RpcSession.RpcError(Parse("{\"code\":-32603,\"message\":\"Internal error\"}")),
                new HttpRequestException(), new IOException(), new TimeoutException(), new OperationCanceledException(),
                new SafeFailure(Fault.GrokCliNotInstalled), new SafeFailure(Fault.GrokVerificationFailed)
            })
            {
                var refresh = new GrokCliRefresh(ValidSource(), Clock, _ => new FakeRpc((_, _) => throw error));
                using var provider = Make(Vendor.Grok, new Handler(_ => throw new InvalidOperationException()), ExpiredSource(), refresh);
                var result = await provider.FetchAsync();
                var expected = error is SafeFailure { Fault: Fault.GrokCliNotInstalled or Fault.GrokVerificationFailed } safe ? safe.Fault : Fault.Network;
                Equal(result.Fault, expected);
                if (expected == Fault.GrokVerificationFailed)
                {
                    Equal(result.GrokState, GrokState.VerificationFailed);
                    Check(!Presentation.CanSignInAgain(result));
                }
                else AssertExpired(result, expected);
            }
            foreach (Exception error in new Exception[] { new TimeoutException(), new OperationCanceledException(), new HttpRequestException() })
            {
                using var provider = Make(Vendor.Grok, new Handler(_ => throw error), ValidSource());
                AssertNotExpired(await provider.FetchAsync(), Fault.Network);
            }
        });
        AsyncTest("explicit unauthenticated RPC errors expire both usage and refresh", async () =>
        {
            foreach (string json in new[]
            {
                "{\"code\":-32603,\"data\":{\"code\":\"UNAUTHENTICATED\"}}",
                "{\"code\":-32000,\"message\":\"Unauthenticated\"}",
                "{\"code\":-32000,\"data\":{\"error\":\"invalid_grant\"}}",
                "{\"code\":401}", "{\"code\":403}"
            })
            {
                var error = RpcSession.RpcError(Parse(json)); Equal(error.Fault, Fault.SignIn);
                var refresh = new GrokCliRefresh(ValidSource(), Clock, _ => new FakeRpc((_, _) => throw error));
                using var provider = Make(Vendor.Grok, new Handler(_ => throw new InvalidOperationException()), ExpiredSource(), refresh);
                AssertExpired(await provider.FetchAsync(), Fault.SignIn);
                var usage = new CodexProvider(Clock, new(new()), () => new FakeRpc((_, _) => throw error));
                Equal((await usage.FetchAsync()).Fault, Fault.SignIn);
            }
            foreach (string json in new[] { "{\"code\":-32603}", "{\"code\":400}", "{\"code\":429}", "{\"message\":\"network unauthenticated proxy unavailable\"}" })
                Equal(RpcSession.RpcError(Parse(json)).Fault, Fault.Network);
            Check(!Presentation.SignInExpired(Fault.RefreshFailed));
        });
        Test("real installed Grok executable passes the native verifier and publisher pins", () =>
        {
            string profile = Environment.GetEnvironmentVariable("USERPROFILE") ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string real = Path.Combine(profile, ".grok", "bin", "grok.exe");
            try { _ = File.GetAttributes(real); }
            catch (FileNotFoundException) { Console.WriteLine("grok-verify-real: Skipped (Grok CLI not installed)"); return; }
            catch (DirectoryNotFoundException) { Console.WriteLine("grok-verify-real: Skipped (Grok CLI not installed)"); return; }
            try
            {
                var signature = new AuthenticodeSignatures().Verify(real);
                if (!GrokPublisher.Accepts(signature))
                    throw new SafeFailure(Fault.GrokVerificationFailed, new(signature.Status == SignatureStatus.Unsigned
                        ? VerificationStatus.Unsigned : signature.Status == SignatureStatus.Valid
                            ? VerificationStatus.PublisherMismatch : signature.Diagnostic, ExecutableLocation.LocalAppData));
                Console.WriteLine("grok-verify-real: Accepted");
            }
            catch (SafeFailure failure)
            {
                Console.WriteLine($"grok-verify-real: Rejected ({failure.Verification?.Status})"); throw;
            }
        });
    }

    private static string HardeningDirectory()
    {
        string directory = Path.Combine(Environment.CurrentDirectory, "artifacts", "tests", "hardening-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory); return directory;
    }

    private static void RunLocalHardeningTests()
    {
        Test("settings replace existing file atomically and never reuse predictable temp name", () =>
        {
            string directory = HardeningDirectory(); var store = new SettingsStore(directory);
            string oldTemp = Path.Combine(directory, "settings.json.tmp"); File.WriteAllText(oldTemp, "preserve");
            store.Save(new() { Theme = Theme.Dark }); Equal(store.Load().Theme, Theme.Dark);
            store.Save(new() { Theme = Theme.Light }); Equal(store.Load().Theme, Theme.Light);
            Equal(File.ReadAllText(oldTemp), "preserve"); Equal(Directory.GetFiles(directory).Length, 2);
            using var held = new FileStream(Path.Combine(directory, "settings.json"), FileMode.Open, FileAccess.Read, FileShare.Read);
            Throws(() => store.Save(new() { Theme = Theme.Dark }));
            Equal(store.Load().Theme, Theme.Light);
            var temporary = Directory.GetFiles(directory, "settings.*.tmp").Where(p => p != oldTemp).ToArray();
            Equal(temporary.Length, 1);
            Check(Guid.TryParseExact(Path.GetFileName(temporary[0])[9..^4], "N", out _));
        });
        Test("settings reject directory junction on read/write and preserve target", () =>
        {
            string directory = HardeningDirectory(), target = Path.Combine(directory, "target"), link = Path.Combine(directory, "link");
            new SettingsStore(target).Save(new() { Theme = Theme.Dark });
            CreateTestJunction(link, target);
            var store = new SettingsStore(link); Equal(store.Load().Theme, Theme.System);
            Throws(() => store.Save(new() { Theme = Theme.Light }));
            Equal(new SettingsStore(target).Load().Theme, Theme.Dark);
            Throws(() => IconExport.Save(link)); Equal(Directory.GetFiles(target).Length, 1);
            string empty = Path.Combine(directory, "empty"), emptyLink = Path.Combine(directory, "empty-link");
            Directory.CreateDirectory(empty); CreateTestJunction(emptyLink, empty);
            Throws(() => IconExport.Save(emptyLink)); Check(!Directory.EnumerateFileSystemEntries(empty).Any());
            Throws(() => IconExport.Save(Path.Combine(emptyLink, "child"))); Check(!Directory.Exists(Path.Combine(empty, "child")));
        });
        Test("settings reject a reparse point at settings.json before read/write", () =>
        {
            string directory = HardeningDirectory(), targetDirectory = Path.Combine(directory, "original"), link = Path.Combine(directory, "settings.json");
            Directory.CreateDirectory(targetDirectory);
            string target = Path.Combine(targetDirectory, "original.json");
            const string content = "{\"Theme\":2}"; File.WriteAllText(target, content);
            // A junction exercises the leaf reparse check without requiring symlink privileges.
            CreateTestJunction(link, targetDirectory);
            var store = new SettingsStore(directory); Equal(store.Load().Theme, Theme.System);
            Throws(() => store.Save(new())); Equal(File.ReadAllText(target), content);
            Check((File.GetAttributes(link) & FileAttributes.ReparsePoint) != 0);
            Equal(Directory.GetFiles(directory).Length, 0);
        });
        Test("icon export refuses nonempty directories, files and occupied output names without overwriting", () =>
        {
            string directory = HardeningDirectory(), path = Path.Combine(directory, "tray-icon-light.ico");
            File.WriteAllText(path, "preserve");
            Throws(() => IconExport.Save(directory)); Equal(Directory.GetFiles(directory).Length, 1);
            Throws(() => IconExport.Save(path));
            Throws(() => { using var file = IconExport.NewFile(path); });
            var family = new TrayIconFamily(Vendor.Grok, 8, false);
            Throws(() => family.Save(path, createNew: true)); Equal(File.ReadAllText(path), "preserve");
            string subdirectory = Path.Combine(HardeningDirectory(), "occupied"); Directory.CreateDirectory(subdirectory);
            Throws(() => IconExport.Save(Path.GetDirectoryName(subdirectory)!));
            string locked = Path.Combine(HardeningDirectory(), "locked.png");
            using var held = new FileStream(locked, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            Throws(() => { using var file = IconExport.NewFile(locked); }); Equal(held.Length, 0L);
        });
        Test("export-icons command rejects occupied paths and invalid arguments with failure exit codes", () =>
        {
            string directory = HardeningDirectory(), file = Path.Combine(directory, "sentinel.txt");
            File.WriteAllText(file, "preserve");
            foreach (string target in new[] { directory, file })
            {
                var result = RunExportCommand(["--export-icons", target]);
                Equal(result.Code, 1); Equal(result.Output.Trim(), "Icon export failed.");
                Equal(File.ReadAllText(file), "preserve"); Equal(Directory.GetFiles(directory).Length, 1);
            }
            Equal(RunExportCommand(["--export-icons"]).Code, 2);
        });
        Test("tray renderer rejects oversized allocations at every geometry entry point", () =>
        {
            foreach (int size in new[] { 0, 15, 257, int.MaxValue })
            {
                Throws(() => { using var bitmap = RingIcon.TrayBitmap(Vendor.Grok, 8, false, size); });
                Throws(() => MacTrayRenderer.GetLayout(8, size, true));
                Throws(() => { using var path = MacTrayRenderer.ArcPath(size); });
                Throws(() => { using var mask = MacTrayRenderer.LogoMask(Vendor.Grok, size, default); });
            }
            using var maximum = RingIcon.TrayBitmap(Vendor.Grok, 8, false, 256); Equal(maximum.Width, 256);
        });
        Test("50 tray percentage toggles keep GDI and USER handles stable without forced GC", () =>
        {
            using var app = new AISubGauge.UI.AppContext(Options.Parse(["--demo", "--autostart", "--lang", "en"]), null,
                settingsStore: new SettingsStore(HardeningDirectory(), readOnly: true));
            Application.DoEvents();
            var toggle = app.SettingsWindow.Controls.OfType<Toggle>().Single(t => t.AccessibleName == app.Text["ShowTrayPercentage"]);
            for (int i = 0; i < 4; i++) { toggle.Checked = !toggle.Checked; Application.DoEvents(); }
            using var process = Process.GetCurrentProcess();
            uint gdi = GetGuiResources(process.Handle, 0), user = GetGuiResources(process.Handle, 1);
            Check(gdi > 0 && user > 0);
            for (int i = 0; i < 50; i++) { toggle.Checked = !toggle.Checked; Application.DoEvents(); }
            uint afterGdi = GetGuiResources(process.Handle, 0), afterUser = GetGuiResources(process.Handle, 1);
            Console.WriteLine($"tray-handles: GDI {gdi}->{afterGdi}; USER {user}->{afterUser}");
            Check(afterGdi <= gdi + 4 && afterUser <= user + 4);
        });
    }

    private static void CreateTestJunction(string link, string target)
    {
        var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"))
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        info.ArgumentList.Add("-NoProfile"); info.ArgumentList.Add("-NonInteractive"); info.ArgumentList.Add("-Command");
        info.ArgumentList.Add($"$ErrorActionPreference='Stop'; New-Item -ItemType Junction -Path '{link.Replace("'", "''")}' -Target '{target.Replace("'", "''")}' | Out-Null");
        using var process = Process.Start(info)!;
        Check(process.WaitForExit(10000)); Equal(process.ExitCode, 0);
        Check((File.GetAttributes(link) & FileAttributes.ReparsePoint) != 0);
    }

    private static (int Code, string Output) RunExportCommand(string[] arguments)
    {
        var info = new ProcessStartInfo(Path.Combine(Environment.CurrentDirectory, "src", "AISubGauge2", "bin", "Release", "net8.0-windows", "AISubGauge2.exe"))
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (string argument in arguments) info.ArgumentList.Add(argument);
        string root = Path.GetFullPath(Path.Combine(RuntimeEnvironment.GetRuntimeDirectory(), "..", "..", ".."));
        info.Environment["DOTNET_ROOT"] = root;
        info.Environment["DOTNET_ROOT_" + RuntimeInformation.ProcessArchitecture.ToString().ToUpperInvariant()] = root;
        info.Environment["DOTNET_DISABLE_GUI_ERRORS"] = "1";
        using var process = Process.Start(info)!;
        var stdout = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync();
        Check(process.WaitForExit(10000)); Equal(stderr.GetAwaiter().GetResult(), "");
        return (process.ExitCode, stdout.GetAwaiter().GetResult());
    }

    [DllImport("user32.dll")] private static extern uint GetGuiResources(IntPtr process, uint flags);
}
