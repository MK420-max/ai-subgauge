using System;
using System.IO;
using System.Text;
using System.Windows.Forms;

namespace AISubGauge.UI;

internal sealed class DiagnosticsPreview : Form
{
    private readonly System.Drawing.Icon _windowIcon = AppBrand.WindowIcon();

    public DiagnosticsPreview(string redactedText)
    {
        Icon = _windowIcon;
        Text = I18n.Get("windows.ai.subgauge.diagnostics.export.preview");
        Width = 680;
        Height = 480;
        StartPosition = FormStartPosition.CenterScreen;
        var preview = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both,
            WordWrap = false, Dock = DockStyle.Fill, Text = redactedText };
        var save = new Button { Text = I18n.Get("windows.save"), Dock = DockStyle.Bottom, Height = 36 };
        save.Click += (_, _) =>
        {
            using var dialog = new SaveFileDialog { Filter = I18n.Get("windows.diagnostics.textFiles"), FileName = I18n.Get("windows.diagnostics.fileName") };
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            try
            {
                // Use the same safe output gate as status: no credential targets or links, no overwrite.
                using FileStream file = LocalFiles.CreateStatusFile(dialog.FileName);
                byte[] bytes = new UTF8Encoding(false).GetBytes(redactedText);
                file.Write(bytes);
                Close();
            }
            catch (Exception) { UiMessage.Show(this, I18n.Get("windows.could.not.save.diagnostics.choose.a.new.local.file"), I18n.Get("app.name")); }
        };
        Controls.Add(preview);
        Controls.Add(save);
        AppTheme.Changed += ApplyTheme;
        ApplyTheme();
    }

    private void ApplyTheme() => ThemedUi.Apply(this);

    protected override void Dispose(bool disposing)
    {
        if (disposing) { AppTheme.Changed -= ApplyTheme; Icon = null; _windowIcon.Dispose(); }
        base.Dispose(disposing);
    }
}
