using AISubGauge.Core;
using AISubGauge.UI;
using System.Drawing;
internal static partial class Program
{
    private static void RunPackagingTests()
    {
        Test("ZIP and SED include current installer safety helper and scripts", () =>
        {
            using var archive = System.IO.Compression.ZipFile.OpenRead(Path.Combine("artifacts", "AISubGauge2-2.0.0-win-x64.zip"));
            string sed = File.ReadAllText(Path.Combine("artifacts", "package.sed"));
            foreach (string name in new[] { "install.ps1", "uninstall.ps1", "InstallSafety.ps1", "InstallFiles.ps1" })
            {
                var entry = archive.GetEntry(name); Check(entry is not null);
                using var input = entry!.Open(); using var output = new MemoryStream(); input.CopyTo(output);
                Check(File.ReadAllBytes(name).SequenceEqual(output.ToArray()));
                Check(sed.Contains("=\"" + name + "\""));
            }
        });
        Test("generated SED launches installer in interactive and both quiet modes", () =>
        {
            var options = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            string section = "";
            foreach (string raw in File.ReadLines(Path.Combine(Environment.CurrentDirectory, "artifacts", "package.sed")))
            {
                string line = raw.Trim();
                if (line.StartsWith('[')) { section = line; continue; }
                if (section != "[Options]" || !line.Contains('=')) continue;
                string[] pair = line.Split('=', 2);
                options.Add(pair[0].Trim(), pair[1].Trim());
            }
            foreach (string key in new[] { "AppLaunched", "UserQuietInstCmd", "AdminQuietInstCmd" })
                Equal(options[key], "cmd.exe /c install.cmd");
            string launcher = File.ReadAllText(Path.Combine(Environment.CurrentDirectory, "artifacts", "package", "install.cmd"));
            Check(launcher.Contains("-File \"%~dp0install.ps1\""));
            Check(launcher.Contains("exit /b %errorlevel%"));
        });
        Test("published EXE embeds the eight reviewed app PNGs without executing the application", () =>
        {
            string path = Path.Combine(Environment.CurrentDirectory, "artifacts", "publish", "AISubGauge2.exe");
            // LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE: inspect resources only.
            IntPtr module = LoadLibraryEx(path, IntPtr.Zero, 0x22); Check(module != IntPtr.Zero);
            try
            {
                var groups = new List<byte[]>();
                ResourceNameCallback collect = (handle, type, name, _) => { groups.Add(ReadResource(handle, type, name)); return true; };
                Check(EnumResourceNames(module, (IntPtr)14, collect, IntPtr.Zero)); Equal(groups.Count, 1);
                using var reader = new BinaryReader(new MemoryStream(groups[0]));
                Equal(reader.ReadUInt16(), (ushort)0); Equal(reader.ReadUInt16(), (ushort)1); Equal(reader.ReadUInt16(), (ushort)RequiredAppIconSizes.Length);
                foreach (int size in RequiredAppIconSizes)
                {
                    byte dimension = size == 256 ? (byte)0 : (byte)size;
                    Equal(reader.ReadByte(), dimension); Equal(reader.ReadByte(), dimension);
                    reader.ReadUInt16(); Equal(reader.ReadUInt16(), (ushort)1); Equal(reader.ReadUInt16(), (ushort)32);
                    int length = reader.ReadInt32(); ushort id = reader.ReadUInt16();
                    byte[] png = ReadResource(module, (IntPtr)3, (IntPtr)id); Equal(png.Length, length);
                    using var stream = new MemoryStream(png); using var frame = new Bitmap(stream);
                    Equal(frame.Width, size); Equal(frame.Height, size);
                    Check(png.SequenceEqual(File.ReadAllBytes(Path.Combine(Environment.CurrentDirectory, "assets", "brand", $"app-light-win-{size}.png"))));
                }
            }
            finally { FreeLibrary(module); }
        });
        Test("distribution includes project and third-party licenses", () =>
        {
            foreach (string name in new[] { "LICENSE", "THIRD_PARTY_NOTICES.md" })
                Check(File.ReadAllBytes(name).SequenceEqual(File.ReadAllBytes(Path.Combine("artifacts", "package", name))));
            string notices = File.ReadAllText("THIRD_PARTY_NOTICES.md");
            Check(notices.Contains(File.ReadAllText(Path.Combine("assets", "logos", "LICENSE-LobeHub.txt"))));
            string runtimeNotices = File.ReadAllText(Path.Combine("artifacts", "package", "DOTNET-NOTICES.txt"));
            Check(runtimeNotices.Contains("Microsoft.NETCore.App.Runtime.win-x64/"));
            Check(runtimeNotices.Contains("Microsoft.WindowsDesktop.App.Runtime.win-x64/"));
            Check(runtimeNotices.Contains("THIRD-PARTY-NOTICES.TXT"));
            string sed = File.ReadAllText(Path.Combine("artifacts", "package.sed"));
            foreach (string name in new[] { "LICENSE", "THIRD_PARTY_NOTICES.md", "DOTNET-NOTICES.txt" })
                Check(sed.Contains("=\"" + name + "\""));
        });
    }
}
