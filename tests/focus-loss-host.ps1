# Standalone STA target: it must keep its own message loop alive during UIA queries.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$form = [Windows.Forms.Form]::new()
$form.Text = 'WICI synthetic non-text target'
$form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
$button = [Windows.Forms.Button]::new()
$button.Text = 'Non-text focus target'
$button.Dock = [Windows.Forms.DockStyle]::Fill
$form.Controls.Add($button)
$form.Add_Shown({ $form.Activate(); $null = $button.Focus() })
try { [Windows.Forms.Application]::Run($form) }
finally { $form.Dispose() }
