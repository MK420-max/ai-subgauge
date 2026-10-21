using System;
using System.Drawing;
using System.Windows.Forms;

namespace AISubGauge.UI;

internal static class ThemedUi
{
    internal static void Apply(Control control)
    {
        control.BackColor = AppTheme.Color(control is TextBox ? "surface" : "background");
        control.ForeColor = UiStyle.Text;
        if (control is Button button)
        {
            button.UseVisualStyleBackColor = false;
            button.FlatStyle = FlatStyle.Flat;
            button.BackColor = AppTheme.Color("surfaceAlt");
            button.FlatAppearance.BorderColor = AppTheme.Color("border");
        }
        foreach (Control child in control.Controls) Apply(child);
    }

    internal static void ApplyMenu(ToolStrip menu)
    {
        menu.Renderer = new ToolStripProfessionalRenderer(new MenuColors()) { RoundedEdges = false };
        menu.BackColor = AppTheme.Color("surface");
        menu.ForeColor = UiStyle.Text;
        foreach (ToolStripItem item in menu.Items)
        {
            item.BackColor = AppTheme.Color("surface");
            item.ForeColor = UiStyle.Text;
            if (item is ToolStripDropDownItem dropdown) ApplyMenu(dropdown.DropDown);
        }
    }

    private sealed class MenuColors : ProfessionalColorTable
    {
        public override Color ToolStripDropDownBackground => AppTheme.Color("surface");
        public override Color MenuBorder => AppTheme.Color("border");
        public override Color MenuItemBorder => AppTheme.Color("border");
        public override Color MenuItemSelected => AppTheme.Color("surfaceAlt");
        public override Color MenuItemSelectedGradientBegin => MenuItemSelected;
        public override Color MenuItemSelectedGradientEnd => MenuItemSelected;
        public override Color MenuItemPressedGradientBegin => MenuItemSelected;
        public override Color MenuItemPressedGradientMiddle => MenuItemSelected;
        public override Color MenuItemPressedGradientEnd => MenuItemSelected;
        public override Color ImageMarginGradientBegin => ToolStripDropDownBackground;
        public override Color ImageMarginGradientMiddle => ToolStripDropDownBackground;
        public override Color ImageMarginGradientEnd => ToolStripDropDownBackground;
        public override Color CheckBackground => AppTheme.Color("surfaceAlt");
        public override Color CheckSelectedBackground => CheckBackground;
        public override Color CheckPressedBackground => CheckBackground;
        public override Color SeparatorDark => AppTheme.Color("border");
        public override Color SeparatorLight => ToolStripDropDownBackground;
    }
}

// Application-authored prompts share the manual theme, including on Windows versions whose
// native MessageBox cannot inherit an application-specific dark appearance.
internal static class UiMessage
{
    internal static DialogResult Show(string text, string caption, MessageBoxButtons buttons = MessageBoxButtons.OK) => Show(null, text, caption, buttons);

    internal static DialogResult Show(IWin32Window? owner, string text, string caption,
        MessageBoxButtons buttons = MessageBoxButtons.OK)
    {
        using var appIcon = AppBrand.WindowIcon();
        using var dialog = new Form { Text = caption, Icon = appIcon, FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterScreen, ShowInTaskbar = false, TopMost = true, MinimizeBox = false,
            MaximizeBox = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = new Padding(20) };
        var layout = new TableLayoutPanel { AutoSize = true, ColumnCount = 1, Dock = DockStyle.Fill };
        var message = new Label { Text = text, AutoSize = true, MaximumSize = new Size(480, 0),
            Margin = new Padding(0, 0, 0, 20), AccessibleRole = AccessibleRole.StaticText };
        var actions = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill };
        var accept = new Button { AutoSize = true, MinimumSize = new Size(90, 32),
            Text = I18n.Get(buttons == MessageBoxButtons.YesNo ? "consent.allow" : "common.ok"),
            DialogResult = buttons == MessageBoxButtons.YesNo ? DialogResult.Yes : DialogResult.OK };
        if (buttons == MessageBoxButtons.YesNo)
        {
            var decline = new Button { AutoSize = true, MinimumSize = new Size(90, 32), Text = I18n.Get("consent.deny"), DialogResult = DialogResult.No };
            actions.Controls.Add(decline);
            dialog.CancelButton = decline;
        }
        else dialog.CancelButton = accept;
        actions.Controls.Add(accept);
        dialog.AcceptButton = accept;
        layout.Controls.Add(message);
        layout.Controls.Add(actions);
        dialog.Controls.Add(layout);
        void Apply() => ThemedUi.Apply(dialog);
        AppTheme.Changed += Apply;
        Apply();
        try { return owner is null ? dialog.ShowDialog() : dialog.ShowDialog(owner); }
        finally { AppTheme.Changed -= Apply; }
    }
}
