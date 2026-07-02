<#
.SYNOPSIS
    Full automation of a domain controller installation (ADDS + DNS + DHCP) for lab setups.
    Single tabbed graphical interface for data entry, unattended execution, and automatic
    resume across the required reboots (rename, then ADDS promotion).

.DESCRIPTION
    "Interactive" phase (normal launch):
        - Checks elevation, Server edition and server state
        - Single tabbed window (Server / Network / Roles / ADDS / DNS / DHCP), laid out like the
          native Windows Server 2022 "Active Directory Domain Services Configuration" wizard,
          but everything is entered once and applied in a single pass
        - Import / Export a ready-made configuration, and preview every command before launch
        - Applies the network, installs the roles, writes the DSRM password, registers the
          resume/viewer tasks, then renames and/or promotes (reboot)

    "Promote" phase (after the rename reboot, via a SYSTEM scheduled task):
        - Decrypts the secrets, promotes the server, re-targets the resume task to Configure

    "Configure" phase (after the promotion reboot, via a SYSTEM scheduled task):
        - Waits for AD, configures DNS forwarders and the DHCP scope, writes the report, cleans up

    Compatible with Windows Server 2019 / 2022 / 2025. Requires PowerShell 5.1+.

.PARAMETER Verbose
    Shows extra details, in particular the values collected in the interactive window.

.PARAMETER Debug
    Asks for confirmation before every DEPLOYMENT command (network, roles, rename, promotion,
    DNS, DHCP). Internal script operations are not affected. Only has an effect during the
    interactive phase (post-reboot phases run automatically).

.NOTES
    Just run the script (right-click > Run with PowerShell, or from an elevated console).
    It relaunches itself elevated if required.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Promote', 'Configure')]
    [string]$Phase = 'Interactive'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  Verbose / debug modes (handled by the script, not via $DebugPreference)
# ---------------------------------------------------------------------------
$Script:VerboseMode = $PSBoundParameters.ContainsKey('Verbose')
$Script:DebugMode   = $PSBoundParameters.ContainsKey('Debug')
if ($Script:VerboseMode) { $VerbosePreference = 'Continue' }
$DebugPreference = 'SilentlyContinue'  # we handle deployment confirmations ourselves

# ---------------------------------------------------------------------------
#  Constants / paths
# ---------------------------------------------------------------------------
$Script:AppDir       = Join-Path $env:ProgramData 'AutoDC'
$Script:StateFile    = Join-Path $Script:AppDir 'state.json'
$Script:LogFile      = Join-Path $Script:AppDir 'AutoDC.log'
$Script:LocalCopy    = Join-Path $Script:AppDir 'Automated-DC-Install.ps1'
$Script:ViewerScript = Join-Path $Script:AppDir 'viewer.ps1'
$Script:TaskName     = 'AutoDC-Resume'
$Script:ViewerTask   = 'AutoDC-Viewer'

if (-not (Test-Path $Script:AppDir)) {
    New-Item -ItemType Directory -Path $Script:AppDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
#  Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')] [string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8
    $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
}

function Write-VerboseInfo {
    param([string]$Message)
    if ($Script:VerboseMode) {
        Write-Verbose $Message
        Write-Log "[VERBOSE] $Message"
    }
}

# ---------------------------------------------------------------------------
#  Elevation
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host 'Elevation required, relaunching as administrator...' -ForegroundColor Yellow
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Definition }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
                 '-File', "`"$scriptPath`"", '-Phase', $Phase)
    if ($Script:VerboseMode) { $argList += '-Verbose' }
    if ($Script:DebugMode)   { $argList += '-Debug' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Host "Unable to relaunch elevated: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host 'Press Enter to quit'
    }
    exit
}

# ===========================================================================
#  HELPERS: network validation
# ===========================================================================
function Test-IPv4Address {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Value.Trim(), [ref]$ip)) { return $false }
    ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) -and
        ($Value.Trim().Split('.').Count -eq 4)
}

function Get-PrefixFromMask {
    param([string]$Mask)
    $bytes = ([System.Net.IPAddress]$Mask).GetAddressBytes()
    $bits  = ($bytes | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
    ($bits.ToCharArray() | Where-Object { $_ -eq '1' }).Count
}

function Get-MaskFromPrefix {
    param([int]$Prefix)
    $bits  = ('1' * $Prefix).PadRight(32, '0')
    $bytes = 0..3 | ForEach-Object { [Convert]::ToInt32($bits.Substring($_ * 8, 8), 2) }
    $bytes -join '.'
}

function Test-SubnetMask {
    param([string]$Mask)
    if (-not (Test-IPv4Address $Mask)) { return $false }
    $bytes = ([System.Net.IPAddress]$Mask).GetAddressBytes()
    $bits  = ($bytes | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
    $bits -match '^1*0*$' -and $bits.Contains('1')
}

function Test-SameSubnet {
    param([string]$Ip1, [string]$Ip2, [int]$Prefix)
    $mask = [System.Net.IPAddress](Get-MaskFromPrefix $Prefix)
    $a = ([System.Net.IPAddress]$Ip1).Address -band $mask.Address
    $b = ([System.Net.IPAddress]$Ip2).Address -band $mask.Address
    $a -eq $b
}

function ConvertTo-IpUInt {
    param([string]$Ip)
    $b = ([System.Net.IPAddress]$Ip).GetAddressBytes()
    [Array]::Reverse($b)
    [System.BitConverter]::ToUInt32($b, 0)
}

# ===========================================================================
#  HELPERS: random password
# ===========================================================================
function New-RandomPassword {
    param([int]$Length = 20)
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnpqrstuvwxyz'
    $digit = '23456789'
    $sym   = '!@#$%^&*-_=+?'
    $all   = $upper + $lower + $digit + $sym
    $chars = @(
        $upper[(Get-Random -Maximum $upper.Length)]
        $lower[(Get-Random -Maximum $lower.Length)]
        $digit[(Get-Random -Maximum $digit.Length)]
        $sym[(Get-Random -Maximum $sym.Length)]
    )
    for ($i = $chars.Count; $i -lt $Length; $i++) {
        $chars += $all[(Get-Random -Maximum $all.Length)]
    }
    -join ($chars | Sort-Object { Get-Random })
}

# ===========================================================================
#  HELPERS: secrets (machine-scope DPAPI) + hostname
# ===========================================================================
function Protect-Secret {
    param([string]$Plain)
    if ([string]::IsNullOrEmpty($Plain)) { return '' }
    Add-Type -AssemblyName System.Security
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
    $enc = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    [Convert]::ToBase64String($enc)
}
function Unprotect-Secret {
    param([string]$Enc)
    if ([string]::IsNullOrEmpty($Enc)) { return '' }
    Add-Type -AssemblyName System.Security
    $bytes = [Convert]::FromBase64String($Enc)
    $dec = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    [System.Text.Encoding]::UTF8.GetString($dec)
}

function Test-Hostname {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    ($Name -match '^(?!-)[A-Za-z0-9-]{1,15}(?<!-)$') -and ($Name -notmatch '^\d+$')
}

# ===========================================================================
#  DEPLOYMENT CONFIRMATION (-Debug mode)
# ===========================================================================
function Confirm-DeployStep {
    param([string]$Description)
    Write-Log $Description
    if (-not $Script:DebugMode) { return }
    # No prompt possible outside the interactive phase (SYSTEM, no desktop): keep going.
    if ($Phase -ne 'Interactive' -or -not [Environment]::UserInteractive) {
        Write-Log "[DEBUG] Automatic execution (non-interactive phase)."
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Deployment command to run:`r`n`r`n$Description`r`n`r`nRun this step?`r`n(Cancel = abort the deployment)",
        '[DEBUG] Confirmation', 'OKCancel', 'Question')
    if ($r -eq [System.Windows.Forms.DialogResult]::Cancel) {
        throw 'Deployment aborted by the user (debug mode).'
    }
}

# ===========================================================================
#  GRAPHICAL INTERFACE (Windows Forms)
# ===========================================================================
function Initialize-WinForms {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
}

function New-FormLabel {
    param($Text, $X, $Y, $Width = 150)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($Width, 20)
    $l
}

function New-FormTextBox {
    param($Text, $X, $Y, $Width = 200)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text = "$Text"
    $t.Location = New-Object System.Drawing.Point($X, $Y)
    $t.Size = New-Object System.Drawing.Size($Width, 22)
    $t
}

function Show-Warning {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show($Message, 'Validation',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
}

function Confirm-YesNo {
    param([string]$Message)
    ([System.Windows.Forms.MessageBox]::Show($Message, 'Confirmation',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning) -eq [System.Windows.Forms.DialogResult]::Yes)
}

# ---------------------------------------------------------------------------
#  Single window with a left navigation tree (ADUC / Windows Server 2022
#  wizard style): Server / Network (+ one child node per NIC) / Roles, plus
#  ADDS / DNS / DHCP nodes shown only when the matching role is checked. Each
#  navigable node carries its content Panel in .Tag. All control references
#  live in $Script:MW so event handlers and the Read/Sync/Set helpers never
#  rely on already-returned function locals.
# ---------------------------------------------------------------------------
function Get-NavOrder {
    # Flatten the tree (top nodes then their children) into a navigation order.
    $order = New-Object System.Collections.ArrayList
    foreach ($top in $Script:MW.Tree.Nodes) {
        [void]$order.Add($top)
        foreach ($child in $top.Nodes) { [void]$order.Add($child) }
    }
    $order
}

function Update-NavButton {
    # The Next button becomes Launch on the last node.
    $order = Get-NavOrder
    $sel = $Script:MW.Tree.SelectedNode
    $isLast = ($order.Count -gt 0 -and $sel -eq $order[$order.Count - 1])
    $Script:MW.BtnNext.Text = if ($isLast) { 'Launch' } else { 'Next >' }
}

function Show-NodePanel {
    # Show the Panel bound to a node (.Tag), hide the others.
    param($Node)
    $p = if ($Node) { $Node.Tag } else { $null }
    foreach ($pan in $Script:MW.Panels) { if ($pan -ne $p) { $pan.Visible = $false } }
    if ($p) { $p.Visible = $true; $p.BringToFront() }
    if ($Node -and $Node -eq $Script:MW.Nodes.Checks) { Update-PrereqChecks }
    Update-NavButton
}

function Sync-RoleNodes {
    # Show/hide the ADDS/DNS/DHCP nodes based on the Roles checkboxes, keeping
    # the node/panel objects (and their entered values) across toggles.
    $mw = $Script:MW
    $nodes = $mw.Tree.Nodes
    foreach ($k in 'Adds', 'Dns', 'Dhcp', 'Checks') {
        $n = $mw.Nodes[$k]
        if ($n -and $nodes.Contains($n)) { [void]$nodes.Remove($n) }
    }
    if ($mw.ChkAdds.Checked) { [void]$nodes.Add($mw.Nodes.Adds) }
    if ($mw.ChkDns.Checked)  { [void]$nodes.Add($mw.Nodes.Dns) }
    if ($mw.ChkDhcp.Checked) { [void]$nodes.Add($mw.Nodes.Dhcp) }
    if ($mw.Nodes.Checks)    { [void]$nodes.Add($mw.Nodes.Checks) }  # always last
    # If the selected node was just removed, fall back to Roles (always present).
    $sel = $mw.Tree.SelectedNode
    if (-not $sel -or $null -eq $sel.TreeView) { $mw.Tree.SelectedNode = $mw.Nodes.Roles }
    Update-NavButton
}

function Update-AddsToggle {
    # New forest vs additional DC: enable only the relevant fields.
    $mw = $Script:MW
    $forest = $mw.RbForest.Checked
    $mw.TbNet.Enabled    = $forest
    $mw.CbLevel.Enabled  = $forest
    $mw.TbSite.Enabled   = -not $forest
    $mw.TbUser.Enabled   = -not $forest
    $mw.TbCred.Enabled   = -not $forest
    $mw.ChkGc.Enabled    = -not $forest
    $mw.ChkRodc.Enabled  = -not $forest
    # NTP and the AD Recycle Bin apply to a new forest
    if ($mw.ChkNtp) { $mw.ChkNtp.Enabled = $forest }
    if ($mw.TbNtp)  { $mw.TbNtp.Enabled  = $forest }
    if ($mw.ChkRecycleBin) { $mw.ChkRecycleBin.Enabled = $forest }
}

function Build-NetworkNodes {
    # Creates one content Panel + one tree child node per adapter, under the
    # Network node. The Network node itself shows a short info panel.
    param($NetworkNode, $Content)
    $mw = $Script:MW
    $mw.NetControls = New-Object System.Collections.ArrayList

    $NetworkNode.Tag.Controls.Add((New-FormLabel 'Select a network adapter in the left pane to configure it.' 20 20 460))

    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -or $_.Status -eq 'Disconnected' } |
                Sort-Object Name
    if (-not $adapters) {
        $NetworkNode.Tag.Controls.Add((New-FormLabel 'No network adapter detected.' 20 50 460))
        return
    }
    $multiNic = (@($adapters).Count -gt 1)

    foreach ($a in $adapters) {
        $cfg   = Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
        $cur   = $cfg.IPv4Address | Select-Object -First 1
        $curGw = ($cfg.IPv4DefaultGateway | Select-Object -First 1).NextHop
        $curDns = ($cfg.DNSServer | Where-Object AddressFamily -eq 2 |
                   Select-Object -ExpandProperty ServerAddresses) -join ', '
        # By default we add 127.0.0.1 (the DC is its own DNS server)
        $dnsDefault = if ($curDns) {
            if ($curDns -notmatch '127\.0\.0\.1') { "$curDns, 127.0.0.1" } else { $curDns }
        } else { '127.0.0.1' }

        $vIp   = if ($cur) { $cur.IPAddress } else { '' }
        $vCidr = if ($cur) { $cur.PrefixLength } else { 24 }

        $panel = New-Object System.Windows.Forms.Panel
        $panel.Dock = 'Fill'; $panel.Visible = $false; $panel.AutoScroll = $true
        $Content.Controls.Add($panel)
        $mw.Panels += $panel

        $macText = if ($a.MacAddress) { $a.MacAddress } else { 'n/a' }
        $panel.Controls.Add((New-FormLabel "Adapter: $($a.Name)     MAC: $macText" 15 12 500))

        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.Text = 'Configure this adapter with a static IP'
        $chk.Location = New-Object System.Drawing.Point(15, 38)
        $chk.Size = New-Object System.Drawing.Size(330, 20)
        $chk.Checked = $true
        $panel.Controls.Add($chk)

        $tbAdName = New-FormTextBox $a.Name  210 68 245
        $tbIp     = New-FormTextBox $vIp     210 101 245
        $tbCidr   = New-FormTextBox $vCidr   210 134 70
        $tbGw     = New-FormTextBox $curGw   210 167 245
        $tbDns    = New-FormTextBox $dnsDefault 210 200 245

        $panel.Controls.Add((New-FormLabel 'Interface name'                 15 70 190))
        $panel.Controls.Add((New-FormLabel 'IP address'                     15 103 190))
        $panel.Controls.Add((New-FormLabel 'Mask (CIDR prefix 0-32)'        15 136 190))
        $panel.Controls.Add((New-FormLabel 'Gateway (blank if none)'        15 169 190))
        $panel.Controls.Add((New-FormLabel 'DNS (comma-separated)'          15 202 190))
        $panel.Controls.Add($tbAdName); $panel.Controls.Add($tbIp); $panel.Controls.Add($tbCidr)
        $panel.Controls.Add($tbGw); $panel.Controls.Add($tbDns)

        # Per-adapter DNS registration (avoid a badly registered multi-homed DC)
        $chkReg = $null
        if ($multiNic) {
            $chkReg = New-Object System.Windows.Forms.CheckBox
            $chkReg.Text = 'Register this adapter in DNS'
            $chkReg.Location = New-Object System.Drawing.Point(15, 236)
            $chkReg.Size = New-Object System.Drawing.Size(440, 20)
            $chkReg.Checked = $true
            $panel.Controls.Add($chkReg)
        }

        # Per-adapter IPv6 toggle (disables the ms_tcpip6 binding on this NIC)
        $yIpv6 = if ($multiNic) { 262 } else { 236 }
        $chkIpv6 = New-Object System.Windows.Forms.CheckBox
        $chkIpv6.Text = 'Disable IPv6 on this adapter'
        $chkIpv6.Location = New-Object System.Drawing.Point(15, $yIpv6)
        $chkIpv6.Size = New-Object System.Drawing.Size(440, 20)
        $panel.Controls.Add($chkIpv6)

        $hint = New-FormLabel "Adapter: $($a.InterfaceDescription)`r`n127.0.0.1 is added by default. On a secondary (WAN) adapter, clear DNS registration." 15 ($yIpv6 + 30) 450
        $hint.Size = New-Object System.Drawing.Size(455, 55)
        $hint.ForeColor = [System.Drawing.Color]::DimGray
        $panel.Controls.Add($hint)

        # The checkbox only drives the IP fields (adapter rename stays possible)
        $boxes = @($tbIp, $tbCidr, $tbGw, $tbDns)
        foreach ($b in $boxes) { $b.Enabled = $chk.Checked }
        $chk.Tag = $boxes
        $chk.Add_CheckedChanged({ param($s, $e) foreach ($b in $s.Tag) { $b.Enabled = $s.Checked } })

        $node = New-Object System.Windows.Forms.TreeNode($a.Name)
        $node.Tag = $panel
        [void]$NetworkNode.Nodes.Add($node)

        [void]$mw.NetControls.Add([pscustomobject]@{
            IfIndex = [int]$a.ifIndex; Name = $a.Name; Node = $node; Panel = $panel; Chk = $chk; AdName = $tbAdName
            Ip = $tbIp; Cidr = $tbCidr; Gw = $tbGw; Dns = $tbDns; RegDns = $chkReg; Ipv6 = $chkIpv6
        })
    }
}

function Build-ServerTab {
    param($Page)
    $mw = $Script:MW
    $Page.Controls.Add((New-FormLabel "Current name: $env:COMPUTERNAME" 20 20 400))

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = 'Rename the server'
    $chk.Location = New-Object System.Drawing.Point(20, 50)
    $chk.Size = New-Object System.Drawing.Size(380, 20)
    $Page.Controls.Add($chk)

    $tbName = New-FormTextBox $env:COMPUTERNAME 150 80 230
    $tbName.Enabled = $false
    $Page.Controls.Add((New-FormLabel 'New name' 20 82 120))
    $Page.Controls.Add($tbName)

    $note = New-FormLabel "1 to 15 characters (letters, digits, hyphens). The server reboots once`r`nbefore promotion to apply the new name." 20 112 420
    $note.Size = New-Object System.Drawing.Size(420, 40)
    $note.ForeColor = [System.Drawing.Color]::DimGray
    $Page.Controls.Add($note)

    $chkPing = New-Object System.Windows.Forms.CheckBox
    $chkPing.Text = 'Allow ping (ICMPv4 echo request) through the firewall'
    $chkPing.Location = New-Object System.Drawing.Point(20, 170)
    $chkPing.Size = New-Object System.Drawing.Size(420, 20)
    $chkPing.Checked = $false
    $Page.Controls.Add($chkPing)

    $chk.Add_CheckedChanged({ $Script:MW.TbNewName.Enabled = $Script:MW.ChkRename.Checked })
    $mw.ChkRename = $chk
    $mw.TbNewName = $tbName
    $mw.ChkAllowPing = $chkPing
}

function Build-RolesTab {
    param($Page)
    $mw = $Script:MW
    $Page.Controls.Add((New-FormLabel 'Select the roles to install and configure:' 20 20 360))

    $chkAdds = New-Object System.Windows.Forms.CheckBox
    $chkAdds.Text = 'ADDS (Active Directory Domain Services)'
    $chkAdds.Location = New-Object System.Drawing.Point(30, 55); $chkAdds.Size = New-Object System.Drawing.Size(360, 20)
    $chkAdds.Checked = $true
    $Page.Controls.Add($chkAdds)

    $chkDns = New-Object System.Windows.Forms.CheckBox
    $chkDns.Text = 'DNS (DNS server + forwarders)'
    $chkDns.Location = New-Object System.Drawing.Point(30, 90); $chkDns.Size = New-Object System.Drawing.Size(360, 20)
    $chkDns.Checked = $true
    $Page.Controls.Add($chkDns)

    $chkDhcp = New-Object System.Windows.Forms.CheckBox
    $chkDhcp.Text = 'DHCP (scope + options)'
    $chkDhcp.Location = New-Object System.Drawing.Point(30, 125); $chkDhcp.Size = New-Object System.Drawing.Size(360, 20)
    $chkDhcp.Checked = $true
    $Page.Controls.Add($chkDhcp)

    $note = New-FormLabel 'Tip: with ADDS, the DNS role is usually installed alongside. The matching tabs appear when a role is checked.' 30 160 400
    $note.Size = New-Object System.Drawing.Size(400, 40)
    $note.ForeColor = [System.Drawing.Color]::DimGray
    $Page.Controls.Add($note)

    $chkAdds.Add_CheckedChanged({ Sync-RoleNodes })
    $chkDns.Add_CheckedChanged({ Sync-RoleNodes })
    $chkDhcp.Add_CheckedChanged({ Sync-RoleNodes })
    $mw.ChkAdds = $chkAdds; $mw.ChkDns = $chkDns; $mw.ChkDhcp = $chkDhcp
}

function Build-AddsTab {
    param($Page)
    $mw = $Script:MW
    $Page.AutoScroll = $true

    # --- Deployment Configuration ---
    $grpDep = New-Object System.Windows.Forms.GroupBox
    $grpDep.Text = 'Deployment Configuration'
    $grpDep.Location = New-Object System.Drawing.Point(10, 10); $grpDep.Size = New-Object System.Drawing.Size(710, 120)
    $Page.Controls.Add($grpDep)

    $rbForest = New-Object System.Windows.Forms.RadioButton
    $rbForest.Text = 'Add a new forest (new root domain)'
    $rbForest.Location = New-Object System.Drawing.Point(15, 22); $rbForest.Size = New-Object System.Drawing.Size(680, 20)
    $grpDep.Controls.Add($rbForest)

    $rbDc = New-Object System.Windows.Forms.RadioButton
    $rbDc.Text = 'Add a domain controller to an existing domain'
    $rbDc.Location = New-Object System.Drawing.Point(15, 48); $rbDc.Size = New-Object System.Drawing.Size(680, 20)
    $grpDep.Controls.Add($rbDc)

    $grpDep.Controls.Add((New-FormLabel 'Domain name (FQDN)' 15 82 200))
    $tbDomain = New-FormTextBox 'tp.lan' 230 80 250
    $grpDep.Controls.Add($tbDomain)

    # --- Domain Controller Options ---
    $grpDc = New-Object System.Windows.Forms.GroupBox
    $grpDc.Text = 'Domain Controller Options'
    $grpDc.Location = New-Object System.Drawing.Point(10, 140); $grpDc.Size = New-Object System.Drawing.Size(710, 195)
    $Page.Controls.Add($grpDc)

    $grpDc.Controls.Add((New-FormLabel 'Forest / domain functional level' 15 25 220))
    $cbLevel = New-Object System.Windows.Forms.ComboBox
    $cbLevel.DropDownStyle = 'DropDownList'
    $cbLevel.Location = New-Object System.Drawing.Point(240, 23); $cbLevel.Size = New-Object System.Drawing.Size(250, 22)
    [void]$cbLevel.Items.AddRange(@('WinThreshold (2016/2019/2022)', 'Win2012R2', 'Default'))
    $cbLevel.SelectedIndex = 0
    $grpDc.Controls.Add($cbLevel)

    $grpDc.Controls.Add((New-FormLabel 'Site name' 15 58 220))
    $tbSite = New-FormTextBox 'Default-First-Site-Name' 240 56 250
    $grpDc.Controls.Add($tbSite)

    $grpDc.Controls.Add((New-FormLabel 'Domain admin account' 15 91 220))
    $tbUser = New-FormTextBox 'EXISTING\Administrator' 240 89 250
    $grpDc.Controls.Add($tbUser)

    $grpDc.Controls.Add((New-FormLabel 'Domain admin password' 15 124 220))
    $tbCred = New-Object System.Windows.Forms.MaskedTextBox
    $tbCred.PasswordChar = '*'
    $tbCred.Location = New-Object System.Drawing.Point(240, 122); $tbCred.Size = New-Object System.Drawing.Size(250, 22)
    $grpDc.Controls.Add($tbCred)

    $chkDnsSrv = New-Object System.Windows.Forms.CheckBox
    $chkDnsSrv.Text = 'DNS server'
    $chkDnsSrv.Location = New-Object System.Drawing.Point(15, 158); $chkDnsSrv.Size = New-Object System.Drawing.Size(180, 20)
    $chkDnsSrv.Checked = $true
    $grpDc.Controls.Add($chkDnsSrv)

    $chkGc = New-Object System.Windows.Forms.CheckBox
    $chkGc.Text = 'Global Catalog (GC)'
    $chkGc.Location = New-Object System.Drawing.Point(230, 158); $chkGc.Size = New-Object System.Drawing.Size(200, 20)
    $chkGc.Checked = $true
    $grpDc.Controls.Add($chkGc)

    $chkRodc = New-Object System.Windows.Forms.CheckBox
    $chkRodc.Text = 'Read-only DC (RODC)'
    $chkRodc.Location = New-Object System.Drawing.Point(450, 158); $chkRodc.Size = New-Object System.Drawing.Size(240, 20)
    $grpDc.Controls.Add($chkRodc)

    # --- DSRM (Directory Services Restore Mode) ---
    $grpDsrm = New-Object System.Windows.Forms.GroupBox
    $grpDsrm.Text = 'DSRM password (restore mode)'
    $grpDsrm.Location = New-Object System.Drawing.Point(10, 345); $grpDsrm.Size = New-Object System.Drawing.Size(710, 110)
    $Page.Controls.Add($grpDsrm)

    $chkRand = New-Object System.Windows.Forms.CheckBox
    $chkRand.Text = 'Generate randomly and write to the Desktop (.txt)'
    $chkRand.Location = New-Object System.Drawing.Point(15, 22); $chkRand.Size = New-Object System.Drawing.Size(650, 20)
    $grpDsrm.Controls.Add($chkRand)

    $grpDsrm.Controls.Add((New-FormLabel 'DSRM password' 15 52 200))
    $tbPwd1 = New-Object System.Windows.Forms.MaskedTextBox
    $tbPwd1.PasswordChar = '*'; $tbPwd1.Location = New-Object System.Drawing.Point(240, 50); $tbPwd1.Size = New-Object System.Drawing.Size(250, 22)
    $grpDsrm.Controls.Add($tbPwd1)

    $grpDsrm.Controls.Add((New-FormLabel 'Confirm' 15 80 200))
    $tbPwd2 = New-Object System.Windows.Forms.MaskedTextBox
    $tbPwd2.PasswordChar = '*'; $tbPwd2.Location = New-Object System.Drawing.Point(240, 78); $tbPwd2.Size = New-Object System.Drawing.Size(250, 22)
    $grpDsrm.Controls.Add($tbPwd2)

    $chkRand.Add_CheckedChanged({
        $Script:MW.TbPwd1.Enabled = -not $Script:MW.ChkDsrmRand.Checked
        $Script:MW.TbPwd2.Enabled = -not $Script:MW.ChkDsrmRand.Checked
    })

    # --- Additional Options ---
    $grpAdd = New-Object System.Windows.Forms.GroupBox
    $grpAdd.Text = 'Additional Options'
    $grpAdd.Location = New-Object System.Drawing.Point(10, 465); $grpAdd.Size = New-Object System.Drawing.Size(710, 85)
    $Page.Controls.Add($grpAdd)

    $grpAdd.Controls.Add((New-FormLabel 'Domain NetBIOS name' 15 25 200))
    $tbNet = New-FormTextBox 'TP' 240 23 250
    $grpAdd.Controls.Add($tbNet)

    $chkDnsDeleg = New-Object System.Windows.Forms.CheckBox
    $chkDnsDeleg.Text = 'Create DNS delegation'
    $chkDnsDeleg.Location = New-Object System.Drawing.Point(15, 52); $chkDnsDeleg.Size = New-Object System.Drawing.Size(650, 20)
    $grpAdd.Controls.Add($chkDnsDeleg)

    # --- Paths ---
    $grpPath = New-Object System.Windows.Forms.GroupBox
    $grpPath.Text = 'Paths'
    $grpPath.Location = New-Object System.Drawing.Point(10, 560); $grpPath.Size = New-Object System.Drawing.Size(710, 130)
    $Page.Controls.Add($grpPath)

    $grpPath.Controls.Add((New-FormLabel 'Database folder' 15 25 200))
    $tbDb = New-FormTextBox 'C:\Windows\NTDS' 240 23 440
    $grpPath.Controls.Add($tbDb)

    $grpPath.Controls.Add((New-FormLabel 'Log files folder' 15 58 200))
    $tbLog = New-FormTextBox 'C:\Windows\NTDS' 240 56 440
    $grpPath.Controls.Add($tbLog)

    $grpPath.Controls.Add((New-FormLabel 'SYSVOL folder' 15 91 200))
    $tbSysvol = New-FormTextBox 'C:\Windows\SYSVOL' 240 89 440
    $grpPath.Controls.Add($tbSysvol)

    # --- Time source (new forest / PDC) ---
    $grpNtp = New-Object System.Windows.Forms.GroupBox
    $grpNtp.Text = 'Time source (new forest / PDC)'
    $grpNtp.Location = New-Object System.Drawing.Point(10, 700); $grpNtp.Size = New-Object System.Drawing.Size(710, 90)
    $Page.Controls.Add($grpNtp)

    $chkNtp = New-Object System.Windows.Forms.CheckBox
    $chkNtp.Text = 'Configure an external NTP time source on this PDC'
    $chkNtp.Location = New-Object System.Drawing.Point(15, 22); $chkNtp.Size = New-Object System.Drawing.Size(650, 20)
    $chkNtp.Checked = $true
    $grpNtp.Controls.Add($chkNtp)

    $grpNtp.Controls.Add((New-FormLabel 'NTP servers (comma-separated)' 15 52 220))
    $tbNtp = New-FormTextBox 'pool.ntp.org,time.windows.com' 240 50 440
    $grpNtp.Controls.Add($tbNtp)

    # --- Forest feature ---
    $chkRecycle = New-Object System.Windows.Forms.CheckBox
    $chkRecycle.Text = 'Enable the AD Recycle Bin (new forest - irreversible once enabled)'
    $chkRecycle.Location = New-Object System.Drawing.Point(20, 800); $chkRecycle.Size = New-Object System.Drawing.Size(560, 20)
    $chkRecycle.Checked = $false
    $Page.Controls.Add($chkRecycle)

    # Save references
    $mw.RbForest = $rbForest; $mw.RbDc = $rbDc; $mw.TbDomain = $tbDomain
    $mw.CbLevel = $cbLevel; $mw.TbSite = $tbSite; $mw.TbUser = $tbUser; $mw.TbCred = $tbCred
    $mw.ChkDnsSrv = $chkDnsSrv; $mw.ChkGc = $chkGc; $mw.ChkRodc = $chkRodc
    $mw.ChkDsrmRand = $chkRand; $mw.TbPwd1 = $tbPwd1; $mw.TbPwd2 = $tbPwd2
    $mw.TbNet = $tbNet; $mw.ChkDnsDeleg = $chkDnsDeleg
    $mw.TbDbPath = $tbDb; $mw.TbLogPath = $tbLog; $mw.TbSysvolPath = $tbSysvol
    $mw.ChkNtp = $chkNtp; $mw.TbNtp = $tbNtp; $mw.ChkRecycleBin = $chkRecycle

    $rbForest.Add_CheckedChanged({ Update-AddsToggle })
    $rbDc.Add_CheckedChanged({ Update-AddsToggle })
    $rbForest.Checked = $true
    Update-AddsToggle
}

function Build-DnsTab {
    param($Page)
    $mw = $Script:MW
    $Page.Controls.Add((New-FormLabel 'Forwarder addresses (one per line):' 20 15 360))

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true; $tb.ScrollBars = 'Vertical'
    $tb.Location = New-Object System.Drawing.Point(20, 40); $tb.Size = New-Object System.Drawing.Size(360, 160)
    $tb.Text = "9.9.9.9`r`n1.1.1.1"
    $Page.Controls.Add($tb)

    $note = New-FormLabel 'Examples: 9.9.9.9 (Quad9), 1.1.1.1 (Cloudflare). Leave empty for no forwarder.' 20 210 400
    $note.Size = New-Object System.Drawing.Size(400, 40)
    $note.ForeColor = [System.Drawing.Color]::DimGray
    $Page.Controls.Add($note)

    $chkRev = New-Object System.Windows.Forms.CheckBox
    $chkRev.Text = 'Create a reverse lookup zone (PTR) for the server subnet'
    $chkRev.Location = New-Object System.Drawing.Point(20, 255); $chkRev.Size = New-Object System.Drawing.Size(400, 20)
    $chkRev.Checked = $true
    $Page.Controls.Add($chkRev)

    $noteRev = New-FormLabel 'The in-addr.arpa zone is derived from the static IP/prefix and created after promotion.' 20 278 420
    $noteRev.Size = New-Object System.Drawing.Size(420, 30)
    $noteRev.ForeColor = [System.Drawing.Color]::DimGray
    $Page.Controls.Add($noteRev)

    $mw.TbForwarders = $tb
    $mw.ChkRevZone = $chkRev
}

function Build-DhcpTab {
    param($Page)
    $mw = $Script:MW
    # Defaults derived from the first static-looking adapter, else a lab default
    $primary = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
               Where-Object { $_.IPv4Address } | Select-Object -First 1
    $baseIp = if ($primary) { ($primary.IPv4Address | Select-Object -First 1).IPAddress } else { '192.168.1.10' }
    $gw     = if ($primary) { ($primary.IPv4DefaultGateway | Select-Object -First 1).NextHop } else { '' }
    $prefix = if ($primary) { ($primary.IPv4Address | Select-Object -First 1).PrefixLength } else { 24 }

    $tbName   = New-FormTextBox 'TP-Scope'                          250 20 250
    $tbStart  = New-FormTextBox ($baseIp -replace '\.\d+$', '.100') 250 55 250
    $tbEnd    = New-FormTextBox ($baseIp -replace '\.\d+$', '.200') 250 90 250
    $tbMask   = New-FormTextBox (Get-MaskFromPrefix $prefix)        250 125 250
    $tbRouter = New-FormTextBox $gw                                 250 160 250
    $tbDns    = New-FormTextBox $baseIp                             250 195 250
    $tbDom    = New-FormTextBox ''                                  250 230 250
    $tbLease  = New-FormTextBox 8                                   250 265 80

    $Page.Controls.Add((New-FormLabel 'Scope name'              20 22 220))
    $Page.Controls.Add((New-FormLabel 'Range start'            20 57 220))
    $Page.Controls.Add((New-FormLabel 'Range end'              20 92 220))
    $Page.Controls.Add((New-FormLabel 'Subnet mask'            20 127 220))
    $Page.Controls.Add((New-FormLabel 'Router (gateway)'       20 162 220))
    $Page.Controls.Add((New-FormLabel 'DNS servers (commas)'   20 197 220))
    $Page.Controls.Add((New-FormLabel 'DNS suffix / domain'    20 232 220))
    $Page.Controls.Add((New-FormLabel 'Lease duration (days)'  20 267 220))
    $Page.Controls.Add($tbName); $Page.Controls.Add($tbStart); $Page.Controls.Add($tbEnd)
    $Page.Controls.Add($tbMask); $Page.Controls.Add($tbRouter); $Page.Controls.Add($tbDns)
    $Page.Controls.Add($tbDom); $Page.Controls.Add($tbLease)

    $mw.TbScopeName = $tbName; $mw.TbStart = $tbStart; $mw.TbEnd = $tbEnd; $mw.TbMask = $tbMask
    $mw.TbRouter = $tbRouter; $mw.TbDhcpDns = $tbDns; $mw.TbDnsDomain = $tbDom; $mw.TbLease = $tbLease

    # --- Reservations (static IP <-> MAC bindings) ---
    $Page.Controls.Add((New-FormLabel 'Reservations (fixed IP per MAC address):' 20 305 400))
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(20, 328)
    $grid.Size = New-Object System.Drawing.Size(560, 150)
    $grid.AllowUserToAddRows = $true
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.AutoSizeColumnsMode = 'Fill'
    $colIp = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colIp.HeaderText = 'IP address'; $colIp.Name = 'Ip'
    $colMac = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colMac.HeaderText = 'MAC (e.g. 00-11-22-33-44-55)'; $colMac.Name = 'Mac'
    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.HeaderText = 'Name / description'; $colName.Name = 'Name'
    [void]$grid.Columns.Add($colIp); [void]$grid.Columns.Add($colMac); [void]$grid.Columns.Add($colName)
    $Page.Controls.Add($grid)

    $note = New-FormLabel 'Optional. One row per reservation. The IP should sit inside (or near) the scope subnet.' 20 482 560
    $note.ForeColor = [System.Drawing.Color]::DimGray
    $Page.Controls.Add($note)
    $mw.GridReservations = $grid

    # --- Exclusion ranges (addresses inside the scope that are NOT leased) ---
    $Page.Controls.Add((New-FormLabel 'Exclusion ranges (addresses NOT handed out):' 20 512 400))
    $gridEx = New-Object System.Windows.Forms.DataGridView
    $gridEx.Location = New-Object System.Drawing.Point(20, 535)
    $gridEx.Size = New-Object System.Drawing.Size(560, 110)
    $gridEx.AllowUserToAddRows = $true
    $gridEx.AllowUserToResizeRows = $false
    $gridEx.RowHeadersVisible = $false
    $gridEx.AutoSizeColumnsMode = 'Fill'
    $colStart = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colStart.HeaderText = 'Exclusion start'; $colStart.Name = 'Start'
    $colEnd = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colEnd.HeaderText = 'Exclusion end'; $colEnd.Name = 'End'
    [void]$gridEx.Columns.Add($colStart); [void]$gridEx.Columns.Add($colEnd)
    $Page.Controls.Add($gridEx)

    $noteEx = New-FormLabel 'Optional. Typically reserve the low addresses for static infrastructure (e.g. .1 to .20).' 20 649 560
    $noteEx.ForeColor = [System.Drawing.Color]::DimGray
    $Page.Controls.Add($noteEx)
    $mw.GridExclusions = $gridEx
}

# ---------------------------------------------------------------------------
#  Prerequisites (pre-flight) checks: environment sanity before the launch
#  that chains two automatic reboots. Reads the live system + current fields.
# ---------------------------------------------------------------------------
function Get-PrereqResults {
    $mw = $Script:MW
    $r = New-Object System.Collections.ArrayList
    function Add-Res { param($Level, $Text) [void]$r.Add([pscustomobject]@{ Level = $Level; Text = $Text }) }

    if (Test-IsAdmin) { Add-Res 'OK' 'Running elevated (administrator).' }
    else { Add-Res 'ERROR' 'Not running as administrator.' }

    try {
        if ((Get-CimInstance Win32_OperatingSystem).ProductType -ne 1) { Add-Res 'OK' 'Windows Server edition detected.' }
        else { Add-Res 'ERROR' 'This is not a Windows Server edition.' }
    } catch { Add-Res 'WARN' 'Could not determine the OS edition.' }

    $staticCount = @($mw.NetControls | Where-Object { $_.Chk.Checked }).Count
    if ($staticCount -gt 0) { Add-Res 'OK' "$staticCount adapter(s) set to a static IP." }
    elseif ($mw.ChkAdds.Checked) { Add-Res 'WARN' 'No static IP configured; a domain controller should use a static address.' }
    else { Add-Res 'OK' 'No static IP (acceptable without ADDS).' }

    try {
        $free = [math]::Round((Get-PSDrive C -ErrorAction Stop).Free / 1GB, 1)
        if ($free -ge 20) { Add-Res 'OK' "System drive free space: $free GB." }
        else { Add-Res 'WARN' "Low free space on C: $free GB (>= 20 GB recommended)." }
    } catch { }

    $pending = $false
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pending = $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pending = $true }
    if (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue) { $pending = $true }
    if ($pending) { Add-Res 'WARN' 'A reboot is already pending; consider rebooting before promotion.' }
    else { Add-Res 'OK' 'No pending reboot.' }

    if ($mw.ChkAdds.Checked) {
        if ($mw.RbForest.Checked) {
            $srv = if ($mw.ChkRename.Checked -and $mw.TbNewName.Text.Trim()) { $mw.TbNewName.Text.Trim() } else { $env:COMPUTERNAME }
            if ($mw.TbNet.Text.Trim().ToUpper() -eq $srv.ToUpper()) { Add-Res 'ERROR' 'Domain NetBIOS equals the server name (promotion would fail).' }
            else { Add-Res 'OK' 'New forest: domain NetBIOS differs from the server name.' }
        } else {
            if (-not $mw.TbUser.Text.Trim() -or -not $mw.TbCred.Text) { Add-Res 'ERROR' 'Additional DC: domain admin account/password is missing.' }
            $dom = $mw.TbDomain.Text.Trim()
            if ($dom) {
                try { $null = Resolve-DnsName -Name $dom -ErrorAction Stop; Add-Res 'OK' "Existing domain '$dom' resolves." }
                catch { Add-Res 'WARN' "Existing domain '$dom' does not resolve yet (check DNS / reachability)." }
            }
        }
    }
    $r
}

function Update-PrereqChecks {
    $res = Get-PrereqResults
    $lines = $res | ForEach-Object { '[{0}] {1}' -f $_.Level, $_.Text }
    $Script:MW.TxtChecks.Text = ($lines -join "`r`n")
}

function Build-ChecksTab {
    param($Page)
    $mw = $Script:MW
    $Page.Controls.Add((New-FormLabel 'Pre-flight checks (review before launching the two-reboot process):' 20 15 560))

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = 'Run checks'; $btn.Location = New-Object System.Drawing.Point(20, 42); $btn.Size = New-Object System.Drawing.Size(110, 26)
    $btn.Add_Click({ Update-PrereqChecks })
    $Page.Controls.Add($btn)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline = $true; $txt.ReadOnly = $true; $txt.ScrollBars = 'Both'; $txt.WordWrap = $false
    $txt.Font = New-Object System.Drawing.Font('Consolas', 9)
    $txt.Location = New-Object System.Drawing.Point(20, 78); $txt.Size = New-Object System.Drawing.Size(620, 380)
    $txt.Anchor = 'Top,Left,Right,Bottom'
    $Page.Controls.Add($txt)
    $mw.TxtChecks = $txt
}

# ---------------------------------------------------------------------------
#  Read + validate every tab into a $data object (or $null on failure).
#  Reuses the shared Test-* helpers; on error it switches to the offending
#  tab and shows the warning, so the "verification phases" always run.
# ---------------------------------------------------------------------------
function Read-MainWindow {
    $mw = $Script:MW

    # ---- Server (rename) ----
    if ($mw.ChkRename.Checked) {
        $name = $mw.TbNewName.Text.Trim()
        if (-not (Test-Hostname $name)) {
            $mw.Tree.SelectedNode = $mw.Nodes.Server
            Show-Warning 'Invalid name (1-15 characters, letters/digits/hyphens, not purely numeric).'; return $null
        }
        $rename = [pscustomobject]@{ NewName = $name; Rename = ($name -ne $env:COMPUTERNAME) }
    } else {
        $rename = [pscustomobject]@{ NewName = $env:COMPUTERNAME; Rename = $false }
    }

    # ---- Network ----
    $network = @()
    foreach ($c in $mw.NetControls) {
        $newName = $c.AdName.Text.Trim()
        if (-not $newName) {
            $mw.Tree.SelectedNode = $c.Node
            Show-Warning "[$($c.Name)] The interface name cannot be empty."; return $null
        }
        $regDns = if ($c.RegDns) { $c.RegDns.Checked } else { $true }
        $noIpv6 = [bool]$c.Ipv6.Checked
        if (-not $c.Chk.Checked) {
            $network += [pscustomobject]@{ IfIndex = $c.IfIndex; Name = $c.Name; NewName = $newName; Static = $false; RegisterDns = $regDns; DisableIpv6 = $noIpv6 }
            continue
        }
        $ip = $c.Ip.Text.Trim(); $cidr = $c.Cidr.Text.Trim()
        $gw = $c.Gw.Text.Trim();  $dns = $c.Dns.Text.Trim()
        $mw.Tree.SelectedNode = $c.Node
        if (-not (Test-IPv4Address $ip)) { Show-Warning "[$($c.Name)] Invalid IP address."; return $null }
        if ($cidr -notmatch '^\d+$' -or [int]$cidr -lt 1 -or [int]$cidr -gt 32) {
            Show-Warning "[$($c.Name)] Invalid CIDR prefix (1-32)."; return $null }
        if ($gw -and -not (Test-IPv4Address $gw)) { Show-Warning "[$($c.Name)] Invalid gateway."; return $null }
        if ($gw -and -not (Test-SameSubnet $ip $gw ([int]$cidr))) {
            Show-Warning "[$($c.Name)] The gateway is not in the same subnet as the IP."; return $null }
        $dnsList = @()
        if ($dns) {
            foreach ($d in ($dns -split ',')) {
                $d = $d.Trim(); if (-not $d) { continue }
                if (-not (Test-IPv4Address $d)) { Show-Warning "[$($c.Name)] Invalid DNS: $d"; return $null }
                $dnsList += $d
            }
        }
        $network += [pscustomobject]@{
            IfIndex = $c.IfIndex; Name = $c.Name; NewName = $newName; Static = $true
            Ip = $ip; Prefix = [int]$cidr; Gateway = $gw; Dns = $dnsList; RegisterDns = $regDns; DisableIpv6 = $noIpv6
        }
    }

    # ---- Roles ----
    if (-not ($mw.ChkAdds.Checked -or $mw.ChkDns.Checked -or $mw.ChkDhcp.Checked)) {
        $mw.Tree.SelectedNode = $mw.Nodes.Roles
        Show-Warning 'Select at least one role.'; return $null
    }
    $roles = [pscustomobject]@{ ADDS = $mw.ChkAdds.Checked; DNS = $mw.ChkDns.Checked; DHCP = $mw.ChkDhcp.Checked }

    # ---- ADDS ----
    $adds = $null
    if ($mw.ChkAdds.Checked) {
        $mw.Tree.SelectedNode = $mw.Nodes.Adds
        $domain = $mw.TbDomain.Text.Trim()
        if ($domain -notmatch '^([A-Za-z0-9](-?[A-Za-z0-9])*)(\.[A-Za-z0-9](-?[A-Za-z0-9])*)+$') {
            Show-Warning 'Invalid FQDN domain name (e.g. tp.lan).'; return $null }
        $newForest = $mw.RbForest.Checked
        $netbios = $mw.TbNet.Text.Trim().ToUpper()
        if ($newForest -and $netbios -notmatch '^[A-Z0-9]{1,15}$') {
            Show-Warning 'Invalid NetBIOS name (1-15 alphanumeric characters).'; return $null }
        $domUser = $mw.TbUser.Text.Trim(); $domPwd = $mw.TbCred.Text
        if (-not $newForest -and (-not $domUser -or -not $domPwd)) {
            Show-Warning 'Domain admin account and password are required for an additional DC.'; return $null }
        if ($mw.ChkDsrmRand.Checked) { $dsrm = New-RandomPassword 20; $random = $true }
        else {
            if ($mw.TbPwd1.Text.Length -lt 8) { Show-Warning 'The DSRM password must be at least 8 characters.'; return $null }
            if ($mw.TbPwd1.Text -cne $mw.TbPwd2.Text) { Show-Warning 'The DSRM passwords do not match.'; return $null }
            $dsrm = $mw.TbPwd1.Text; $random = $false
        }
        # NetBIOS of the domain must differ from the (effective) server name for a new forest
        if ($newForest) {
            $effName = if ($rename.Rename) { $rename.NewName } else { $env:COMPUTERNAME }
            if ($netbios -and ($netbios -eq $effName.ToUpper())) {
                Show-Warning ("The domain NetBIOS name ('{0}') is identical to the server name ('{1}').`r`nThis is not allowed for a new forest (promotion would fail: NetBIOS name already in use).`r`n`r`nChoose a different domain NetBIOS, or rename the server." -f $netbios, $effName)
                return $null
            }
        }
        $levelMap = @{ 'WinThreshold (2016/2019/2022)' = 'WinThreshold'; 'Win2012R2' = 'Win2012R2'; 'Default' = 'Default' }
        $adds = [pscustomobject]@{
            NewForest = $newForest; DomainFqdn = $domain; NetBIOS = $netbios
            FuncLevel = $levelMap[$mw.CbLevel.SelectedItem]; SiteName = $mw.TbSite.Text.Trim()
            DomainUser = $domUser; DomainPwd = $domPwd; DsrmPassword = $dsrm; DsrmRandom = $random
            InstallDns = [bool]$mw.ChkDnsSrv.Checked; GlobalCatalog = [bool]$mw.ChkGc.Checked
            Rodc = [bool]$mw.ChkRodc.Checked; CreateDnsDelegation = [bool]$mw.ChkDnsDeleg.Checked
            DatabasePath = $mw.TbDbPath.Text.Trim(); LogPath = $mw.TbLogPath.Text.Trim(); SysvolPath = $mw.TbSysvolPath.Text.Trim()
            ConfigureNtp = ($newForest -and [bool]$mw.ChkNtp.Checked); NtpServers = $mw.TbNtp.Text.Trim()
            EnableRecycleBin = ($newForest -and [bool]$mw.ChkRecycleBin.Checked)
        }
    }

    # ---- DNS ----
    $dns = $null
    if ($mw.ChkDns.Checked) {
        $mw.Tree.SelectedNode = $mw.Nodes.Dns
        $fwd = @()
        foreach ($line in $mw.TbForwarders.Lines) {
            $v = $line.Trim(); if (-not $v) { continue }
            if (-not (Test-IPv4Address $v)) { Show-Warning "Invalid forwarder: $v"; return $null }
            $fwd += $v
        }
        $dns = [pscustomobject]@{ Forwarders = $fwd; CreateReverseZone = [bool]$mw.ChkRevZone.Checked }
    }

    # ---- DHCP ----
    $dhcp = $null
    if ($mw.ChkDhcp.Checked) {
        $mw.Tree.SelectedNode = $mw.Nodes.Dhcp
        $name  = $mw.TbScopeName.Text.Trim()
        $start = $mw.TbStart.Text.Trim(); $end = $mw.TbEnd.Text.Trim(); $mask = $mw.TbMask.Text.Trim()
        if (-not $name) { Show-Warning 'Scope name is required.'; return $null }
        if (-not (Test-IPv4Address $start)) { Show-Warning 'Invalid range start.'; return $null }
        if (-not (Test-IPv4Address $end))   { Show-Warning 'Invalid range end.'; return $null }
        if (-not (Test-SubnetMask $mask))   { Show-Warning 'Invalid subnet mask.'; return $null }
        $prefix = Get-PrefixFromMask $mask
        if (-not (Test-SameSubnet $start $end $prefix)) {
            Show-Warning 'The range start and end are not in the same subnet.'; return $null }
        if ((ConvertTo-IpUInt $start) -gt (ConvertTo-IpUInt $end)) {
            Show-Warning 'The range start must be lower than or equal to the range end.'; return $null }
        $router = $mw.TbRouter.Text.Trim()
        if ($router -and -not (Test-IPv4Address $router)) { Show-Warning 'Invalid router.'; return $null }
        if ($router -and -not (Test-SameSubnet $start $router $prefix)) {
            if (-not (Confirm-YesNo "The gateway $router is not in the scope subnet ($start /$prefix).`r`nClients will not be able to reach it. Continue anyway?")) { return $null }
        }
        $dnsList = @(); $dnsOut = @()
        foreach ($d in ($mw.TbDhcpDns.Text -split ',')) {
            $d = $d.Trim(); if (-not $d) { continue }
            if (-not (Test-IPv4Address $d)) { Show-Warning "Invalid DHCP DNS: $d"; return $null }
            $dnsList += $d
            if (-not (Test-SameSubnet $start $d $prefix)) { $dnsOut += $d }
        }
        if ($dnsOut.Count -gt 0) {
            if (-not (Confirm-YesNo "The following DNS server(s) are not in the scope subnet:`r`n$($dnsOut -join ', ')`r`nMake sure they stay reachable. Continue anyway?")) { return $null }
        }
        if ($mw.TbLease.Text.Trim() -notmatch '^\d+$' -or [int]$mw.TbLease.Text.Trim() -lt 1) {
            Show-Warning 'Invalid lease duration (days).'; return $null }
        # Reservations (fixed IP <-> MAC)
        $reservations = @()
        if ($mw.GridReservations) {
            foreach ($row in $mw.GridReservations.Rows) {
                if ($row.IsNewRow) { continue }
                $rIp   = "$($row.Cells['Ip'].Value)".Trim()
                $rMac  = "$($row.Cells['Mac'].Value)".Trim()
                $rName = "$($row.Cells['Name'].Value)".Trim()
                if (-not $rIp -and -not $rMac -and -not $rName) { continue }
                if (-not (Test-IPv4Address $rIp)) { Show-Warning "Reservation: invalid IP '$rIp'."; return $null }
                $macHex = ($rMac -replace '[^0-9A-Fa-f]', '')
                if ($macHex.Length -ne 12) { Show-Warning "Reservation: invalid MAC '$rMac' (12 hex digits expected)."; return $null }
                $macNorm = (($macHex -replace '(..)(?=.)', '$1-')).ToUpper()
                $reservations += [pscustomobject]@{ Ip = $rIp; Mac = $macNorm; Name = $rName }
            }
        }
        # Exclusion ranges
        $exclusions = @()
        if ($mw.GridExclusions) {
            foreach ($row in $mw.GridExclusions.Rows) {
                if ($row.IsNewRow) { continue }
                $xs = "$($row.Cells['Start'].Value)".Trim()
                $xe = "$($row.Cells['End'].Value)".Trim()
                if (-not $xs -and -not $xe) { continue }
                if (-not (Test-IPv4Address $xs)) { Show-Warning "Exclusion: invalid start '$xs'."; return $null }
                if (-not (Test-IPv4Address $xe)) { Show-Warning "Exclusion: invalid end '$xe'."; return $null }
                if ((ConvertTo-IpUInt $xs) -gt (ConvertTo-IpUInt $xe)) { Show-Warning "Exclusion: start '$xs' is greater than end '$xe'."; return $null }
                $exclusions += [pscustomobject]@{ Start = $xs; End = $xe }
            }
        }
        $dhcp = [pscustomobject]@{
            ScopeName = $name; Start = $start; End = $end; Mask = $mask
            Router = $router; Dns = $dnsList; DnsDomain = $mw.TbDnsDomain.Text.Trim(); LeaseDays = [int]$mw.TbLease.Text.Trim()
            Reservations = $reservations; Exclusions = $exclusions
        }
    }

    @{ Rename = $rename; Network = $network; Roles = $roles; Adds = $adds; Dns = $dns; Dhcp = $dhcp
       AllowPing = [bool]$mw.ChkAllowPing.Checked }
}

# ---------------------------------------------------------------------------
#  Fill the window controls from a loaded configuration (Import).
# ---------------------------------------------------------------------------
function Set-MainWindowFromData {
    param($Data)
    $mw = $Script:MW

    if ($Data.Rename) {
        $mw.ChkRename.Checked = [bool]$Data.Rename.Rename
        if ($Data.Rename.NewName) { $mw.TbNewName.Text = $Data.Rename.NewName }
    }
    if ($null -ne $Data.AllowPing) { $mw.ChkAllowPing.Checked = [bool]$Data.AllowPing }

    if ($Data.Network) {
        foreach ($n in $Data.Network) {
            $c = $mw.NetControls | Where-Object { $_.IfIndex -eq [int]$n.IfIndex } | Select-Object -First 1
            if (-not $c) { continue }
            $c.Chk.Checked = [bool]$n.Static
            if ($n.NewName) { $c.AdName.Text = $n.NewName }
            if ($n.Static) {
                $c.Ip.Text   = "$($n.Ip)"
                $c.Cidr.Text = "$($n.Prefix)"
                $c.Gw.Text   = "$($n.Gateway)"
                $c.Dns.Text  = ($n.Dns -join ', ')
            }
            if ($c.RegDns -and ($null -ne $n.RegisterDns)) { $c.RegDns.Checked = [bool]$n.RegisterDns }
            if ($c.Ipv6 -and ($null -ne $n.DisableIpv6)) { $c.Ipv6.Checked = [bool]$n.DisableIpv6 }
        }
    }

    if ($Data.Roles) {
        $mw.ChkAdds.Checked = [bool]$Data.Roles.ADDS
        $mw.ChkDns.Checked  = [bool]$Data.Roles.DNS
        $mw.ChkDhcp.Checked = [bool]$Data.Roles.DHCP
    }
    Sync-RoleNodes

    if ($Data.Adds) {
        $a = $Data.Adds
        if ($a.NewForest) { $mw.RbForest.Checked = $true } else { $mw.RbDc.Checked = $true }
        if ($a.DomainFqdn) { $mw.TbDomain.Text = $a.DomainFqdn }
        if ($a.NetBIOS)    { $mw.TbNet.Text = $a.NetBIOS }
        switch ($a.FuncLevel) {
            'WinThreshold' { $mw.CbLevel.SelectedIndex = 0 }
            'Win2012R2'    { $mw.CbLevel.SelectedIndex = 1 }
            'Default'      { $mw.CbLevel.SelectedIndex = 2 }
        }
        if ($a.SiteName)   { $mw.TbSite.Text = $a.SiteName }
        if ($a.DomainUser) { $mw.TbUser.Text = $a.DomainUser }
        if ($null -ne $a.InstallDns)          { $mw.ChkDnsSrv.Checked = [bool]$a.InstallDns }
        if ($null -ne $a.GlobalCatalog)       { $mw.ChkGc.Checked = [bool]$a.GlobalCatalog }
        if ($null -ne $a.Rodc)                { $mw.ChkRodc.Checked = [bool]$a.Rodc }
        if ($null -ne $a.CreateDnsDelegation) { $mw.ChkDnsDeleg.Checked = [bool]$a.CreateDnsDelegation }
        if ($a.DatabasePath) { $mw.TbDbPath.Text = $a.DatabasePath }
        if ($a.LogPath)      { $mw.TbLogPath.Text = $a.LogPath }
        if ($a.SysvolPath)   { $mw.TbSysvolPath.Text = $a.SysvolPath }
        if ($null -ne $a.ConfigureNtp) { $mw.ChkNtp.Checked = [bool]$a.ConfigureNtp }
        if ($a.NtpServers)   { $mw.TbNtp.Text = $a.NtpServers }
        if ($null -ne $a.EnableRecycleBin) { $mw.ChkRecycleBin.Checked = [bool]$a.EnableRecycleBin }
        $mw.ChkDsrmRand.Checked = [bool]$a.DsrmRandom
        Update-AddsToggle
    }

    if ($Data.Dns) {
        if ($Data.Dns.Forwarders) { $mw.TbForwarders.Text = ($Data.Dns.Forwarders -join "`r`n") }
        if ($null -ne $Data.Dns.CreateReverseZone) { $mw.ChkRevZone.Checked = [bool]$Data.Dns.CreateReverseZone }
    }

    if ($Data.Dhcp) {
        $d = $Data.Dhcp
        if ($d.ScopeName) { $mw.TbScopeName.Text = $d.ScopeName }
        if ($d.Start)     { $mw.TbStart.Text = $d.Start }
        if ($d.End)       { $mw.TbEnd.Text = $d.End }
        if ($d.Mask)      { $mw.TbMask.Text = $d.Mask }
        $mw.TbRouter.Text    = "$($d.Router)"
        $mw.TbDhcpDns.Text   = $(if ($d.Dns -is [array]) { $d.Dns -join ', ' } else { "$($d.Dns)" })
        $mw.TbDnsDomain.Text = "$($d.DnsDomain)"
        if ($d.LeaseDays) { $mw.TbLease.Text = "$($d.LeaseDays)" }
        if ($mw.GridReservations) {
            $mw.GridReservations.Rows.Clear()
            foreach ($r in @($d.Reservations)) {
                if (-not $r) { continue }
                [void]$mw.GridReservations.Rows.Add($r.Ip, $r.Mac, $r.Name)
            }
        }
        if ($mw.GridExclusions) {
            $mw.GridExclusions.Rows.Clear()
            foreach ($x in @($d.Exclusions)) {
                if (-not $x) { continue }
                [void]$mw.GridExclusions.Rows.Add($x.Start, $x.End)
            }
        }
    }
}

# ---------------------------------------------------------------------------
#  The single window with a left navigation tree. Returns the collected $data
#  on Launch, else $null.
# ---------------------------------------------------------------------------
function Show-MainWindow {
    $Script:MW = @{ Nodes = @{}; Panels = @(); Data = $null }
    $mw = $Script:MW

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'AutoDC - Domain controller configuration'
    $form.Size = New-Object System.Drawing.Size(820, 680)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(720, 560)
    $mw.Form = $form

    # ---- Left pane layout: tweak these numbers to taste ----------------------
    $PaneWidth        = 200   # initial width of the left navigation pane (px)
    $PaneMinWidth     = 130   # minimum width when dragging the splitter (px)
    $PaneBorderLeft   = 6     # empty border around the pane (px)
    $PaneBorderTop    = 6
    $PaneBorderRight  = 4
    $PaneBorderBottom = 6
    $SplitterWidth    = 5     # grab width of the drag handle (px)
    # --------------------------------------------------------------------------

    # Bottom button bar (compact buttons)
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Bottom'; $bar.Height = 42

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'; $flow.FlowDirection = 'RightToLeft'; $flow.Padding = New-Object System.Windows.Forms.Padding(6)
    $bar.Controls.Add($flow)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'; $btnCancel.Size = New-Object System.Drawing.Size(66, 26)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $btnCancel

    # Single Next/Launch button: 'Next >' until the last node, then 'Launch'.
    $btnNext = New-Object System.Windows.Forms.Button
    $btnNext.Text = 'Next >'; $btnNext.Size = New-Object System.Drawing.Size(86, 26)
    $mw.BtnNext = $btnNext

    $btnPreview = New-Object System.Windows.Forms.Button
    $btnPreview.Text = 'Preview'; $btnPreview.Size = New-Object System.Drawing.Size(86, 26)

    $btnExport = New-Object System.Windows.Forms.Button
    $btnExport.Text = 'Export'; $btnExport.Size = New-Object System.Drawing.Size(66, 26)

    $btnImport = New-Object System.Windows.Forms.Button
    $btnImport.Text = 'Import'; $btnImport.Size = New-Object System.Drawing.Size(66, 26)

    $flow.Controls.AddRange(@($btnCancel, $btnNext, $btnPreview, $btnExport, $btnImport))

    # Left navigation pane (tree wrapped in a padded host so there is a border
    # all around it), a mouse-draggable splitter, and the right content host.
    $tree = New-Object System.Windows.Forms.TreeView
    $tree.Dock = 'Fill'; $tree.HideSelection = $false; $tree.BorderStyle = 'FixedSingle'
    $mw.Tree = $tree

    $paneHost = New-Object System.Windows.Forms.Panel
    $paneHost.Dock = 'Left'; $paneHost.Width = $PaneWidth
    $paneHost.Padding = New-Object System.Windows.Forms.Padding($PaneBorderLeft, $PaneBorderTop, $PaneBorderRight, $PaneBorderBottom)
    $paneHost.Controls.Add($tree)

    $split = New-Object System.Windows.Forms.Splitter
    $split.Dock = 'Left'; $split.Width = $SplitterWidth; $split.MinSize = $PaneMinWidth

    $content = New-Object System.Windows.Forms.Panel
    $content.Dock = 'Fill'

    # Docking add-order matters (verified): Fill first, then splitter, then the
    # left pane, then the bottom bar last (so the bar spans the full width).
    $form.Controls.Add($content)
    $form.Controls.Add($split)
    $form.Controls.Add($paneHost)
    $form.Controls.Add($bar)

    # Content panels (one per navigable node); only the selected one is visible.
    $newPanel = {
        $p = New-Object System.Windows.Forms.Panel
        $p.Dock = 'Fill'; $p.Visible = $false; $p.AutoScroll = $true
        $content.Controls.Add($p); $Script:MW.Panels += $p
        $p
    }
    $pServer  = & $newPanel
    $pNetInfo = & $newPanel
    $pRoles   = & $newPanel
    $pAdds    = & $newPanel
    $pDns     = & $newPanel
    $pDhcp    = & $newPanel
    $pChecks  = & $newPanel

    # Tree nodes; ADDS/DNS/DHCP/Checks are added/removed by Sync-RoleNodes.
    $nServer  = New-Object System.Windows.Forms.TreeNode('Server');  $nServer.Tag  = $pServer
    $nNetwork = New-Object System.Windows.Forms.TreeNode('Network'); $nNetwork.Tag = $pNetInfo
    $nRoles   = New-Object System.Windows.Forms.TreeNode('Roles');   $nRoles.Tag   = $pRoles
    $tree.Nodes.AddRange([System.Windows.Forms.TreeNode[]]@($nServer, $nNetwork, $nRoles))
    $mw.Nodes.Server = $nServer; $mw.Nodes.Network = $nNetwork; $mw.Nodes.Roles = $nRoles
    $nAdds = New-Object System.Windows.Forms.TreeNode('ADDS'); $nAdds.Tag = $pAdds; $mw.Nodes.Adds = $nAdds
    $nDns  = New-Object System.Windows.Forms.TreeNode('DNS');  $nDns.Tag  = $pDns;  $mw.Nodes.Dns  = $nDns
    $nDhcp = New-Object System.Windows.Forms.TreeNode('DHCP'); $nDhcp.Tag = $pDhcp; $mw.Nodes.Dhcp = $nDhcp
    $nChecks = New-Object System.Windows.Forms.TreeNode('Prerequisites'); $nChecks.Tag = $pChecks; $mw.Nodes.Checks = $nChecks

    Build-ServerTab   $pServer
    Build-NetworkNodes -NetworkNode $nNetwork -Content $content
    Build-RolesTab    $pRoles
    Build-AddsTab     $pAdds
    Build-DnsTab      $pDns
    Build-DhcpTab     $pDhcp
    Build-ChecksTab   $pChecks

    $tree.Add_AfterSelect({ param($s, $e) Show-NodePanel $e.Node })
    Sync-RoleNodes
    $tree.ExpandAll()
    $tree.SelectedNode = $nServer
    Show-NodePanel $nServer

    $btnImport.Add_Click({
        $loaded = Import-AnswerFile
        if ($loaded) { Set-MainWindowFromData -Data $loaded }
    })
    $btnExport.Add_Click({
        $d = Read-MainWindow
        if ($d) { Export-AnswerFile -Data $d }
    })
    $btnPreview.Add_Click({
        $d = Read-MainWindow
        if ($d) { Show-CommandPreview -Text (Build-CommandPreview -Data $d) }
    })
    $btnNext.Add_Click({
        $order = Get-NavOrder
        $i = $order.IndexOf($Script:MW.Tree.SelectedNode)
        if ($i -lt 0) { $i = 0 }
        if ($i -lt $order.Count - 1) {
            $Script:MW.Tree.SelectedNode = $order[$i + 1]
            return
        }
        # Last node -> Launch
        $d = Read-MainWindow
        if (-not $d) { return }
        # Prerequisite gate: block (with override) on hard errors
        $pErrors = @(Get-PrereqResults | Where-Object { $_.Level -eq 'ERROR' })
        if ($pErrors.Count -gt 0) {
            $msg = "Prerequisite errors:`r`n" + (($pErrors | ForEach-Object { "  - $($_.Text)" }) -join "`r`n") + "`r`n`r`nLaunch anyway?"
            if ([System.Windows.Forms.MessageBox]::Show($msg, 'Prerequisites', 'YesNo', 'Warning') -ne [System.Windows.Forms.DialogResult]::Yes) {
                $Script:MW.Tree.SelectedNode = $Script:MW.Nodes.Checks
                return
            }
        }
        $s = Build-SummaryText $d
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "$($s.Text)`r`n$($s.Warning)`r`n`r`nStart the installation now?",
            'Confirm launch', 'OKCancel', $(if ($s.IsError) { 'Warning' } else { 'Information' }))
        if ($confirm -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $Script:MW.Data = $d
        $Script:MW.Form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $Script:MW.Form.Close()
    })

    $dr = $form.ShowDialog()
    if ($dr -eq [System.Windows.Forms.DialogResult]::OK) { return $mw.Data }
    return $null
}

# ===========================================================================
#  COMMAND PREVIEW (dry-run listing, secrets masked)
# ===========================================================================
function Build-CommandPreview {
    param($Data)
    $sb = New-Object System.Text.StringBuilder
    $rename = $Data.Rename; $network = $Data.Network; $roles = $Data.Roles
    $adds = $Data.Adds; $dns = $Data.Dns; $dhcp = $Data.Dhcp
    $mask = '******'

    [void]$sb.AppendLine('# ================= AutoDC - command preview =================')
    [void]$sb.AppendLine('# The following commands will be run (in this order). Secrets are masked.')
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('# --- Network ---')
    foreach ($n in $network) {
        if ($n.NewName -and $n.NewName -ne $n.Name) {
            [void]$sb.AppendLine("Get-NetAdapter -InterfaceIndex $($n.IfIndex) | Rename-NetAdapter -NewName '$($n.NewName)'")
        }
        if ($null -ne $n.RegisterDns) {
            [void]$sb.AppendLine("Set-DnsClient -InterfaceIndex $($n.IfIndex) -RegisterThisConnectionsAddress `$$([bool]$n.RegisterDns)")
        }
        if ($n.Static) {
            [void]$sb.AppendLine("Set-NetIPInterface -InterfaceIndex $($n.IfIndex) -Dhcp Disabled")
            $gw = if ($n.Gateway) { " -DefaultGateway $($n.Gateway)" } else { '' }
            [void]$sb.AppendLine("New-NetIPAddress -InterfaceIndex $($n.IfIndex) -IPAddress $($n.Ip) -PrefixLength $($n.Prefix)$gw")
            if ($n.Dns -and $n.Dns.Count -gt 0) {
                [void]$sb.AppendLine("Set-DnsClientServerAddress -InterfaceIndex $($n.IfIndex) -ServerAddresses $($n.Dns -join ',')")
            }
        }
        if ($n.DisableIpv6) {
            [void]$sb.AppendLine("Get-NetAdapter -InterfaceIndex $($n.IfIndex) | Disable-NetAdapterBinding -ComponentID ms_tcpip6")
        }
    }
    [void]$sb.AppendLine('')

    [void]$sb.AppendLine('# --- Roles ---')
    if ($roles.ADDS) { [void]$sb.AppendLine('Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools') }
    if ($roles.DNS)  { [void]$sb.AppendLine('Install-WindowsFeature -Name DNS -IncludeManagementTools') }
    if ($roles.DHCP) { [void]$sb.AppendLine('Install-WindowsFeature -Name DHCP -IncludeManagementTools') }
    if ($Data.AllowPing) {
        [void]$sb.AppendLine("New-NetFirewallRule -Name AutoDC-Allow-ICMPv4-In -DisplayName 'AutoDC - Allow ICMPv4 (ping)' -Protocol ICMPv4 -IcmpType 8 -Direction Inbound -Action Allow -Profile Any")
    }
    [void]$sb.AppendLine('')

    if ($rename.Rename) {
        [void]$sb.AppendLine('# --- Rename (reboot) ---')
        [void]$sb.AppendLine("Rename-Computer -NewName '$($rename.NewName)' -Force")
        [void]$sb.AppendLine('Restart-Computer -Force   # automatic resume after reboot')
        [void]$sb.AppendLine('')
    }

    if ($adds) {
        [void]$sb.AppendLine('# --- ADDS promotion (reboot) ---')
        $paths = ''
        if ($adds.DatabasePath) { $paths += " -DatabasePath '$($adds.DatabasePath)'" }
        if ($adds.LogPath)      { $paths += " -LogPath '$($adds.LogPath)'" }
        if ($adds.SysvolPath)   { $paths += " -SysvolPath '$($adds.SysvolPath)'" }
        $deleg = if ($adds.CreateDnsDelegation) { ' -CreateDnsDelegation' } else { '' }
        if ($adds.NewForest) {
            [void]$sb.AppendLine("Install-ADDSForest -DomainName '$($adds.DomainFqdn)' -DomainNetbiosName '$($adds.NetBIOS)' ``")
            [void]$sb.AppendLine("    -ForestMode $($adds.FuncLevel) -DomainMode $($adds.FuncLevel) -InstallDns:`$$([bool]$adds.InstallDns)$deleg$paths ``")
            [void]$sb.AppendLine("    -SafeModeAdministratorPassword (ConvertTo-SecureString '$mask' -AsPlainText -Force) -Force")
        } else {
            $gc = if (-not $adds.GlobalCatalog) { ' -NoGlobalCatalog' } else { '' }
            $ro = if ($adds.Rodc) { ' -ReadOnlyReplica' } else { '' }
            [void]$sb.AppendLine("`$cred = New-Object PSCredential('$($adds.DomainUser)', (ConvertTo-SecureString '$mask' -AsPlainText -Force))")
            [void]$sb.AppendLine("Install-ADDSDomainController -DomainName '$($adds.DomainFqdn)' -Credential `$cred -SiteName '$($adds.SiteName)' ``")
            [void]$sb.AppendLine("    -InstallDns:`$$([bool]$adds.InstallDns)$gc$ro$deleg$paths ``")
            [void]$sb.AppendLine("    -SafeModeAdministratorPassword (ConvertTo-SecureString '$mask' -AsPlainText -Force) -Force")
        }
        [void]$sb.AppendLine('# Reboot, then automatic post-configuration (DNS / DHCP).')
        if ($adds.NewForest -and $adds.ConfigureNtp) {
            [void]$sb.AppendLine("w32tm /config /manualpeerlist:'$($adds.NtpServers)' /syncfromflags:manual /reliable:yes /update   # PDC time source (post-reboot)")
        }
        if ($adds.NewForest -and $adds.EnableRecycleBin) {
            [void]$sb.AppendLine("Enable-ADOptionalFeature 'Recycle Bin Feature' -Scope ForestOrConfigurationSet -Target <forest> -Confirm:`$false   # (post-reboot)")
        }
        [void]$sb.AppendLine('')
    }

    if ($dns -and $dns.Forwarders -and $dns.Forwarders.Count -gt 0) {
        [void]$sb.AppendLine('# --- DNS forwarders (post-reboot) ---')
        [void]$sb.AppendLine("Set-DnsServerForwarder -IPAddress $($dns.Forwarders -join ',')")
        [void]$sb.AppendLine('')
    }

    if ($dns -and $dns.CreateReverseZone -and $adds) {
        $pn = $network | Where-Object Static | Select-Object -First 1
        if ($pn) {
            [void]$sb.AppendLine('# --- Reverse DNS zone (post-reboot) ---')
            [void]$sb.AppendLine("Add-DnsServerPrimaryZone -NetworkId '$(Get-NetworkId -Ip $pn.Ip -Prefix $pn.Prefix)' -ReplicationScope Domain")
            [void]$sb.AppendLine('')
        }
    }

    if ($dhcp) {
        [void]$sb.AppendLine('# --- DHCP (post-reboot) ---')
        if ($adds) { [void]$sb.AppendLine('Add-DhcpServerInDC -DnsName <server-fqdn> -IPAddress <server-ip>   # AD authorization') }
        [void]$sb.AppendLine("Add-DhcpServerv4Scope -Name '$($dhcp.ScopeName)' -StartRange $($dhcp.Start) -EndRange $($dhcp.End) ``")
        [void]$sb.AppendLine("    -SubnetMask $($dhcp.Mask) -LeaseDuration $($dhcp.LeaseDays).00:00:00 -State Active")
        $opt = @()
        if ($dhcp.Router) { $opt += "-Router $($dhcp.Router)" }
        if ($dhcp.Dns -and $dhcp.Dns.Count -gt 0) { $opt += "-DnsServer $($dhcp.Dns -join ',')" }
        if ($dhcp.DnsDomain) { $opt += "-DnsDomain '$($dhcp.DnsDomain)'" }
        if ($opt.Count -gt 0) { [void]$sb.AppendLine("Set-DhcpServerv4OptionValue -ScopeId <scope-id> $($opt -join ' ')") }
        foreach ($x in @($dhcp.Exclusions)) {
            if (-not $x) { continue }
            [void]$sb.AppendLine("Add-DhcpServerv4ExclusionRange -ScopeId <scope-id> -StartRange $($x.Start) -EndRange $($x.End)")
        }
        foreach ($r in @($dhcp.Reservations)) {
            if (-not $r) { continue }
            $rn = if ($r.Name) { " -Name '$($r.Name)'" } else { '' }
            [void]$sb.AppendLine("Add-DhcpServerv4Reservation -ScopeId <scope-id> -IPAddress $($r.Ip) -ClientId $($r.Mac)$rn")
        }
        [void]$sb.AppendLine('')
    }

    $sb.ToString()
}

function Show-CommandPreview {
    param([string]$Text)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'AutoDC - command preview'
    $form.Size = New-Object System.Drawing.Size(760, 560)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(500, 300)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Both'; $tb.WordWrap = $false
    $tb.Font = New-Object System.Drawing.Font('Consolas', 9)
    $tb.Dock = 'Fill'
    $tb.Text = $Text
    $form.Controls.Add($tb)

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Bottom'; $bar.Height = 44
    $form.Controls.Add($bar)
    $tb.BringToFront()

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Close'; $btnClose.Size = New-Object System.Drawing.Size(100, 30)
    $btnClose.Location = New-Object System.Drawing.Point(640, 7)
    $btnClose.Anchor = 'Top,Right'
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $bar.Controls.Add($btnClose)
    $form.AcceptButton = $btnClose; $form.CancelButton = $btnClose

    [void]$form.ShowDialog()
}

# ===========================================================================
#  STATE (persistence between phases)
# ===========================================================================
function Save-State { param($State) $State | ConvertTo-Json -Depth 6 | Set-Content -Path $Script:StateFile -Encoding UTF8 }
function Get-State {
    if (-not (Test-Path $Script:StateFile)) { return $null }
    Get-Content -Path $Script:StateFile -Raw | ConvertFrom-Json
}

# ===========================================================================
#  ANSWER FILE (save / load the configuration)
# ===========================================================================
function Import-AnswerFile {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'AutoDC answer file (*.json)|*.json|All files (*.*)|*.*'
    $dlg.Title  = 'Load an AutoDC configuration'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    try {
        $json = Get-Content -Path $dlg.FileName -Raw | ConvertFrom-Json
    } catch { Show-Warning "Unreadable file: $($_.Exception.Message)"; return $null }
    Write-Log "Configuration loaded: $($dlg.FileName)" 'OK'
    @{ Rename = $json.Rename; Network = $json.Network; Roles = $json.Roles
       Adds = $json.Adds; Dns = $json.Dns; Dhcp = $json.Dhcp; AllowPing = $json.AllowPing }
}

function Export-AnswerFile {
    param($Data)
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter   = 'AutoDC answer file (*.json)|*.json'
    $dlg.Title    = 'Save the configuration'
    $dlg.FileName = 'AutoDC-config.json'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    # Copy WITHOUT secrets (never written to disk)
    $export = @{ Rename = $Data.Rename; Network = $Data.Network; Roles = $Data.Roles
                 Dns = $Data.Dns; Dhcp = $Data.Dhcp; Adds = $null; AllowPing = $Data.AllowPing }
    if ($Data.Adds) {
        $export.Adds = [pscustomobject]@{
            NewForest = $Data.Adds.NewForest; DomainFqdn = $Data.Adds.DomainFqdn; NetBIOS = $Data.Adds.NetBIOS
            FuncLevel = $Data.Adds.FuncLevel; SiteName = $Data.Adds.SiteName; DomainUser = $Data.Adds.DomainUser
            DsrmRandom = $Data.Adds.DsrmRandom; DsrmPassword = ''; DomainPwd = ''
            InstallDns = $Data.Adds.InstallDns; GlobalCatalog = $Data.Adds.GlobalCatalog; Rodc = $Data.Adds.Rodc
            CreateDnsDelegation = $Data.Adds.CreateDnsDelegation
            DatabasePath = $Data.Adds.DatabasePath; LogPath = $Data.Adds.LogPath; SysvolPath = $Data.Adds.SysvolPath
            ConfigureNtp = $Data.Adds.ConfigureNtp; NtpServers = $Data.Adds.NtpServers
            EnableRecycleBin = $Data.Adds.EnableRecycleBin
        }
    }
    try {
        ([pscustomobject]$export) | ConvertTo-Json -Depth 6 | Set-Content -Path $dlg.FileName -Encoding UTF8
        Write-Log "Configuration saved: $($dlg.FileName)" 'OK'
        [System.Windows.Forms.MessageBox]::Show(
            "Configuration saved:`r`n$($dlg.FileName)`r`n`r`nNote: passwords (DSRM, domain admin) are NOT included, for security reasons. You will need to re-enter them on the next load.",
            'Save', 'OK', 'Information') | Out-Null
    } catch { Show-Warning "Save failed: $($_.Exception.Message)" }
}

function Write-ErrorReport {
    param([string]$Message)
    $file = Join-Path (Join-Path $env:PUBLIC 'Desktop') ("AutoDC-ERROR-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $lines = @(
        '===================================================='
        '  AutoDC - INSTALLATION FAILED'
        '===================================================='
        "Date    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Server  : $env:COMPUTERNAME"
        ''
        $Message
        ''
        "Full log: $($Script:LogFile)"
        '===================================================='
    )
    try { Set-Content -Path $file -Value $lines -Encoding UTF8; Write-Log "Error report written: $file" 'WARN' } catch { }
}

# ===========================================================================
#  DEPLOYMENT ACTIONS
# ===========================================================================
function Set-NetworkConfiguration {
    param($Network)
    foreach ($n in $Network) {
        # Guard (answer file from another machine): skip an adapter that is absent here
        if (-not (Get-NetAdapter -InterfaceIndex $n.IfIndex -ErrorAction SilentlyContinue)) {
            Write-Log "Adapter index $($n.IfIndex) ('$($n.NewName)') not found on this machine, skipped." 'WARN'
            continue
        }
        # Optional adapter rename
        if ($n.NewName -and $n.NewName -ne $n.Name) {
            Confirm-DeployStep "Rename network adapter '$($n.Name)' to '$($n.NewName)'"
            try {
                Get-NetAdapter -InterfaceIndex $n.IfIndex | Rename-NetAdapter -NewName $n.NewName -ErrorAction Stop
                Write-Log "Adapter '$($n.Name)' renamed to '$($n.NewName)'." 'OK'
            } catch { Write-Log "Failed to rename adapter '$($n.Name)': $($_.Exception.Message)" 'WARN' }
        }

        # Per-adapter DNS registration (avoid a badly registered multi-homed DC)
        if ($null -ne $n.RegisterDns) {
            try {
                Set-DnsClient -InterfaceIndex $n.IfIndex -RegisterThisConnectionsAddress ([bool]$n.RegisterDns) -ErrorAction Stop
                if (-not $n.RegisterDns) { Write-Log "Adapter '$($n.NewName)': DNS registration disabled." 'OK' }
            } catch { Write-Log "Adapter '$($n.NewName)': could not set DNS registration: $($_.Exception.Message)" 'WARN' }
        }

        # Optional per-adapter IPv6 disable (unbinds ms_tcpip6 on this NIC only)
        if ($n.DisableIpv6) {
            Confirm-DeployStep "Disable IPv6 on adapter '$($n.NewName)'"
            try {
                Get-NetAdapter -InterfaceIndex $n.IfIndex | Disable-NetAdapterBinding -ComponentID 'ms_tcpip6' -ErrorAction Stop
                Write-Log "Adapter '$($n.NewName)': IPv6 disabled." 'OK'
            } catch { Write-Log "Adapter '$($n.NewName)': could not disable IPv6: $($_.Exception.Message)" 'WARN' }
        }

        if (-not $n.Static) { Write-Log "Adapter '$($n.NewName)': IP left unchanged."; continue }

        Confirm-DeployStep "Configure adapter '$($n.NewName)' with static IP $($n.Ip)/$($n.Prefix)"
        try {
            Set-NetIPInterface -InterfaceIndex $n.IfIndex -Dhcp Disabled -ErrorAction SilentlyContinue
            Get-NetIPAddress -InterfaceIndex $n.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Get-NetRoute -InterfaceIndex $n.IfIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

            $params = @{ InterfaceIndex = $n.IfIndex; IPAddress = $n.Ip; PrefixLength = $n.Prefix }
            if ($n.Gateway) { $params.DefaultGateway = $n.Gateway }
            New-NetIPAddress @params | Out-Null

            if ($n.Dns -and $n.Dns.Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $n.IfIndex -ServerAddresses $n.Dns
            }
            Write-Log "Adapter '$($n.NewName)' configured ($($n.Ip)/$($n.Prefix))." 'OK'
        } catch {
            Write-Log "Failed to configure '$($n.NewName)': $($_.Exception.Message)" 'ERROR'
            throw
        }
    }
}

function Install-Roles {
    param($Roles)
    $features = @()
    if ($Roles.ADDS) { $features += 'AD-Domain-Services' }
    if ($Roles.DNS)  { $features += 'DNS' }
    if ($Roles.DHCP) { $features += 'DHCP' }
    foreach ($f in $features) {
        Confirm-DeployStep "Installing role: $f"
        Install-WindowsFeature -Name $f -IncludeManagementTools | Out-Null
        Write-Log "Role $f installed." 'OK'
    }
}

function Set-PingFirewall {
    # Allow inbound ICMPv4 echo request (ping) through the firewall.
    Confirm-DeployStep 'Allow ping (inbound ICMPv4 echo request) through the firewall'
    try {
        $ruleName = 'AutoDC-Allow-ICMPv4-In'
        if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name $ruleName -DisplayName 'AutoDC - Allow ICMPv4 (ping)' `
                -Protocol ICMPv4 -IcmpType 8 -Direction Inbound -Action Allow -Profile Any -ErrorAction Stop | Out-Null
        }
        Write-Log 'Ping (ICMPv4 echo request) allowed through the firewall.' 'OK'
    } catch { Write-Log "Could not allow ping: $($_.Exception.Message)" 'WARN' }
}

function Register-ViewerTask {
    # Log-follow window at logon (live tracking after reboot)
    $viewer = @'
$ErrorActionPreference = 'SilentlyContinue'
$log = 'C:\ProgramData\AutoDC\AutoDC.log'
$Host.UI.RawUI.WindowTitle = 'AutoDC - installation progress'
Write-Host '================ AutoDC progress (info window) ================' -ForegroundColor Cyan
Write-Host "Log: $log" -ForegroundColor DarkGray
Write-Host ''
Get-Content -Path $log -Tail 200 -Wait | ForEach-Object {
    if     ($_ -match '\[ERROR\]') { Write-Host $_ -ForegroundColor Red }
    elseif ($_ -match '\[WARN\]')  { Write-Host $_ -ForegroundColor Yellow }
    elseif ($_ -match '\[OK\]')    { Write-Host $_ -ForegroundColor Green }
    else                           { Write-Host $_ }
    if ($_ -match 'Installation complete') {
        Add-Type -AssemblyName System.Windows.Forms
        $thanks = "Installation completed successfully!`r`n`r`nThank you for using AutoDC.`r`n`r`n   Author: Taeckens.M`r`n   GitHub: github.com/aractuse`r`n`r`n----------------------------------------------------`r`nBe sure to check out ADFlow, my other tool:`r`nautomated creation of Active Directory objects`r`n(users, groups, OUs...) from a simple file.`r`n`r`nAlso available on: github.com/aractuse"
        [System.Windows.Forms.MessageBox]::Show($thanks, "Thank you for using AutoDC", 'OK', 'Information') | Out-Null
        Write-Host ''
        Write-Host 'Installation complete. Press Enter to close this window...' -ForegroundColor Green
        $null = Read-Host
        exit
    }
}
'@
    # The progress window is optional: its failure must never stop the deployment.
    try {
        Set-Content -Path $Script:ViewerScript -Value $viewer -Encoding UTF8
        $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File `"$($Script:ViewerScript)`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        # BUILTIN\Users (S-1-5-32-545): the window shows in the session of whoever logs on
        $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $Script:ViewerTask -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Write-Log "Progress task '$($Script:ViewerTask)' registered (window at next logon)." 'OK'
    } catch {
        Write-Log "Progress task not created (non-blocking): $($_.Exception.Message)" 'WARN'
    }
}

function Register-ResumeTask {
    param([ValidateSet('Promote', 'Configure')] [string]$NextPhase = 'Configure')
    if ($PSCommandPath -ne $Script:LocalCopy) {
        Copy-Item -Path $PSCommandPath -Destination $Script:LocalCopy -Force
    }
    $arg = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$($Script:LocalCopy)`" -Phase $NextPhase"
    if ($Script:VerboseMode) { $arg += ' -Verbose' }   # we do not propagate -Debug (no prompt under SYSTEM)
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $Script:TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "Resume task '$($Script:TaskName)' registered (next phase: $NextPhase)." 'OK'
}

function Unregister-ResumeTask {
    Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $Script:ViewerTask -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Path $Script:ViewerScript -Force -ErrorAction SilentlyContinue
    Write-Log 'Resume/progress tasks removed.' 'OK'
}

function Invoke-Promotion {
    param($Adds, $InstallDns)
    Import-Module ADDSDeployment -ErrorAction Stop
    $securePwd = ConvertTo-SecureString $Adds.DsrmPassword -AsPlainText -Force

    $common = @{
        DomainName                    = $Adds.DomainFqdn
        SafeModeAdministratorPassword = $securePwd
        InstallDns                    = [bool]$InstallDns
        NoRebootOnCompletion          = $false
        Force                         = $true
    }
    if ($Adds.CreateDnsDelegation) { $common.CreateDnsDelegation = $true }
    if ($Adds.DatabasePath) { $common.DatabasePath = $Adds.DatabasePath }
    if ($Adds.LogPath)      { $common.LogPath = $Adds.LogPath }
    if ($Adds.SysvolPath)   { $common.SysvolPath = $Adds.SysvolPath }

    if ($Adds.NewForest) {
        Confirm-DeployStep "Promotion: new forest '$($Adds.DomainFqdn)' (NetBIOS $($Adds.NetBIOS), level $($Adds.FuncLevel))"
        Install-ADDSForest @common `
            -DomainNetbiosName $Adds.NetBIOS -ForestMode $Adds.FuncLevel -DomainMode $Adds.FuncLevel | Out-Null
    } else {
        Confirm-DeployStep "Promotion: additional DC in '$($Adds.DomainFqdn)' (site $($Adds.SiteName))"
        $secCred = ConvertTo-SecureString $Adds.DomainPwd -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($Adds.DomainUser, $secCred)
        $dcParams = @{ Credential = $cred; SiteName = $Adds.SiteName }
        if ($null -ne $Adds.GlobalCatalog -and -not $Adds.GlobalCatalog) { $dcParams.NoGlobalCatalog = $true }
        if ($Adds.Rodc) { $dcParams.ReadOnlyReplica = $true }
        Install-ADDSDomainController @common @dcParams | Out-Null
    }
}

function Write-DsrmFile {
    param($Adds)
    if (-not $Adds.DsrmRandom) { return }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $file = Join-Path $desktop ("DSRM-{0}-{1}.txt" -f $Adds.DomainFqdn, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $content = @"
====================================================
  DSRM PASSWORD (auto-generated)
====================================================
Domain   : $($Adds.DomainFqdn)
Date     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Password : $($Adds.DsrmPassword)

Keep this file in a safe place, then delete it.
====================================================
"@
    Set-Content -Path $file -Value $content -Encoding UTF8
    Write-Log "Random DSRM password written to the Desktop: $file" 'OK'
}

# ===========================================================================
#  CONFIGURE PHASE: DNS forwarders + DHCP (post-reboot)
# ===========================================================================
function Wait-ForActiveDirectory {
    param([int]$TimeoutSeconds = 600)
    Write-Log 'Waiting for Active Directory to become available...'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $adws = Get-Service -Name ADWS -ErrorAction SilentlyContinue
            if ($adws -and $adws.Status -eq 'Running') {
                Import-Module ActiveDirectory -ErrorAction Stop
                Get-ADDomain -ErrorAction Stop | Out-Null
                Write-Log 'Active Directory available.' 'OK'
                return $true
            }
        } catch { }
        Start-Sleep -Seconds 10
    }
    Write-Log 'Timeout: AD not available.' 'ERROR'
    return $false
}

function Set-DnsForwarders {
    param($Forwarders)
    if (-not (Get-Service -Name DNS -ErrorAction SilentlyContinue)) { Write-Log 'DNS service absent, forwarders skipped.' 'WARN'; return }
    if (-not $Forwarders -or $Forwarders.Count -eq 0) { Write-Log 'No forwarder to configure.'; return }
    Confirm-DeployStep "Configure DNS forwarders: $($Forwarders -join ', ')"
    try {
        Set-DnsServerForwarder -IPAddress $Forwarders -PassThru | Out-Null
        Write-Log "DNS forwarders configured: $($Forwarders -join ', ')" 'OK'
    } catch { Write-Log "Failed to configure forwarders: $($_.Exception.Message)" 'ERROR' }
}

function Get-NetworkId {
    # Returns the network id in CIDR form, e.g. 192.168.10.0/24
    param([string]$Ip, [int]$Prefix)
    $ipb  = ([System.Net.IPAddress]$Ip).GetAddressBytes()
    $mb   = ([System.Net.IPAddress](Get-MaskFromPrefix $Prefix)).GetAddressBytes()
    $net  = 0..3 | ForEach-Object { $ipb[$_] -band $mb[$_] }
    "{0}/{1}" -f ($net -join '.'), $Prefix
}

function Set-ReverseDnsZone {
    # AD-integrated reverse lookup (PTR) zone for the server subnet.
    param([string]$Ip, [int]$Prefix)
    if (-not (Get-Service -Name DNS -ErrorAction SilentlyContinue)) { Write-Log 'DNS service absent, reverse zone skipped.' 'WARN'; return }
    if (-not $Ip -or -not $Prefix) { Write-Log 'No static IP/prefix, reverse zone skipped.' 'WARN'; return }
    $netId = Get-NetworkId -Ip $Ip -Prefix $Prefix
    Confirm-DeployStep "Create AD-integrated reverse DNS zone for $netId"
    try {
        Import-Module DnsServer -ErrorAction Stop
        Add-DnsServerPrimaryZone -NetworkId $netId -ReplicationScope 'Domain' -ErrorAction Stop
        Write-Log "Reverse DNS zone created ($netId)." 'OK'
    } catch { Write-Log "Reverse zone warning ($netId): $($_.Exception.Message)" 'WARN' }
}

function Set-NtpTimeSource {
    # Point the PDC (forest root) at an external NTP source. The whole domain
    # then follows the PDC, so bad PDC time otherwise breaks Kerberos.
    param([string]$NtpServers)
    $peers = ($NtpServers -split '[,; ]+' | Where-Object { $_ }) -join ' '
    if (-not $peers) { Write-Log 'No NTP server given, time source unchanged.' 'WARN'; return }
    Confirm-DeployStep "Configure external NTP time source on the PDC: $peers"
    try {
        & w32tm /config /manualpeerlist:"$peers" /syncfromflags:manual /reliable:yes /update | Out-Null
        Restart-Service -Name w32time -ErrorAction SilentlyContinue
        & w32tm /resync /rediscover 2>$null | Out-Null
        Write-Log "NTP time source configured on the PDC ($peers)." 'OK'
    } catch { Write-Log "NTP configuration warning: $($_.Exception.Message)" 'WARN' }
}

function Enable-AdRecycleBin {
    # Enable the AD Recycle Bin optional feature (forest-wide, irreversible).
    Confirm-DeployStep 'Enable the AD Recycle Bin (forest-wide)'
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $forest = (Get-ADForest).RootDomain
        $feature = Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'"
        if ($feature -and $feature.EnabledScopes.Count -gt 0) {
            Write-Log 'AD Recycle Bin already enabled.' 'OK'
        } else {
            Enable-ADOptionalFeature -Identity 'Recycle Bin Feature' `
                -Scope ForestOrConfigurationSet -Target $forest -Confirm:$false -ErrorAction Stop
            Write-Log "AD Recycle Bin enabled on forest '$forest'." 'OK'
        }
    } catch { Write-Log "AD Recycle Bin warning: $($_.Exception.Message)" 'WARN' }
}

function Add-DhcpReservations {
    param($ScopeId, $Reservations)
    foreach ($r in @($Reservations)) {
        if (-not $r -or -not $r.Ip -or -not $r.Mac) { continue }
        try {
            $p = @{ ScopeId = $ScopeId; IPAddress = $r.Ip; ClientId = $r.Mac }
            if ($r.Name) { $p.Name = $r.Name }
            Add-DhcpServerv4Reservation @p -ErrorAction Stop
            Write-Log "DHCP reservation added: $($r.Ip) <-> $($r.Mac)." 'OK'
        } catch { Write-Log "DHCP reservation failed ($($r.Ip) / $($r.Mac)): $($_.Exception.Message)" 'WARN' }
    }
}

function Add-DhcpExclusions {
    param($ScopeId, $Exclusions)
    foreach ($x in @($Exclusions)) {
        if (-not $x -or -not $x.Start -or -not $x.End) { continue }
        try {
            Add-DhcpServerv4ExclusionRange -ScopeId $ScopeId -StartRange $x.Start -EndRange $x.End -ErrorAction Stop
            Write-Log "DHCP exclusion added: $($x.Start) - $($x.End)." 'OK'
        } catch { Write-Log "DHCP exclusion failed ($($x.Start)-$($x.End)): $($_.Exception.Message)" 'WARN' }
    }
}

function Set-DhcpConfiguration {
    param($Dhcp, $ServerFqdn, $ServerIp)
    Import-Module DhcpServer -ErrorAction Stop
    Confirm-DeployStep "Authorize and configure the DHCP server, scope '$($Dhcp.ScopeName)' [$($Dhcp.Start)-$($Dhcp.End)]"
    try {
        $authorized = Get-DhcpServerInDC -ErrorAction SilentlyContinue |
                      Where-Object { $_.DnsName -like "$ServerFqdn*" -or $_.IPAddress -eq $ServerIp }
        if (-not $authorized) {
            Add-DhcpServerInDC -DnsName $ServerFqdn -IPAddress $ServerIp -ErrorAction Stop
            Write-Log "DHCP server authorized in AD ($ServerFqdn / $ServerIp)." 'OK'
        } else { Write-Log 'DHCP server already authorized in AD.' }
    } catch { Write-Log "DHCP authorization warning: $($_.Exception.Message)" 'WARN' }

    try {
        $regPath = 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12'
        if (Test-Path $regPath) { Set-ItemProperty -Path $regPath -Name ConfigurationState -Value 2 }
        Restart-Service -Name DHCPServer -Force -ErrorAction SilentlyContinue
    } catch { }

    try {
        $existing = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
                    Where-Object { $_.StartRange.IPAddressToString -eq $Dhcp.Start }
        if ($existing) {
            Write-Log "A scope with this range start already exists (ScopeId $($existing.ScopeId)), creation skipped." 'WARN'
            $scopeId = $existing.ScopeId
        } else {
            $scope = Add-DhcpServerv4Scope -Name $Dhcp.ScopeName -StartRange $Dhcp.Start -EndRange $Dhcp.End `
                        -SubnetMask $Dhcp.Mask -LeaseDuration ([TimeSpan]::FromDays($Dhcp.LeaseDays)) -State Active -PassThru
            $scopeId = $scope.ScopeId
            Write-Log "Scope '$($Dhcp.ScopeName)' created (ScopeId $scopeId)." 'OK'
        }
        $optParams = @{ ScopeId = $scopeId }
        if ($Dhcp.Router) { $optParams.Router = $Dhcp.Router }
        if ($Dhcp.Dns -and $Dhcp.Dns.Count -gt 0) { $optParams.DnsServer = $Dhcp.Dns }
        if ($Dhcp.DnsDomain) { $optParams.DnsDomain = $Dhcp.DnsDomain }
        if ($optParams.Count -gt 1) {
            Set-DhcpServerv4OptionValue @optParams
            Write-Log 'DHCP options (router / DNS / domain) applied.' 'OK'
        }
        Add-DhcpExclusions -ScopeId $scopeId -Exclusions $Dhcp.Exclusions
        Add-DhcpReservations -ScopeId $scopeId -Reservations $Dhcp.Reservations
    } catch { Write-Log "Failed to configure DHCP scope: $($_.Exception.Message)" 'ERROR' }
}

function Set-StandaloneDhcp {
    param($Dhcp)
    Confirm-DeployStep "Create DHCP scope '$($Dhcp.ScopeName)' (without AD authorization)"
    try {
        Import-Module DhcpServer -ErrorAction Stop
        Add-DhcpServerv4Scope -Name $Dhcp.ScopeName -StartRange $Dhcp.Start -EndRange $Dhcp.End `
            -SubnetMask $Dhcp.Mask -LeaseDuration ([TimeSpan]::FromDays($Dhcp.LeaseDays)) -State Active
        $opt = @{ ScopeId = ($Dhcp.Start -replace '\.\d+$', '.0') }
        if ($Dhcp.Router) { $opt.Router = $Dhcp.Router }
        if ($Dhcp.Dns -and $Dhcp.Dns.Count -gt 0) { $opt.DnsServer = $Dhcp.Dns }
        if ($Dhcp.DnsDomain) { $opt.DnsDomain = $Dhcp.DnsDomain }
        Set-DhcpServerv4OptionValue @opt
        Add-DhcpExclusions -ScopeId $opt.ScopeId -Exclusions $Dhcp.Exclusions
        Add-DhcpReservations -ScopeId $opt.ScopeId -Reservations $Dhcp.Reservations
        Write-Log "DHCP scope '$($Dhcp.ScopeName)' created (without AD authorization)." 'OK'
    } catch { Write-Log "Standalone DHCP failed: $($_.Exception.Message)" 'ERROR' }
}

function Write-CompletionReport {
    param($State)
    $publicDesktop = Join-Path $env:PUBLIC 'Desktop'
    $file = Join-Path $publicDesktop ("AutoDC-Report-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $lines = @()
    $lines += '===================================================='
    $lines += '  DEPLOYMENT REPORT - Domain Controller'
    $lines += '===================================================='
    $lines += "Date           : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += "Server         : $env:COMPUTERNAME"
    if ($State.Adds) {
        $lines += "Domain         : $($State.Adds.DomainFqdn)"
        $lines += "Type           : $(if ($State.Adds.NewForest) { 'New forest' } else { 'Additional DC' })"
    }
    if ($State.Dns)  { $lines += "DNS forwarders : $($State.Dns.Forwarders -join ', ')" }
    if ($State.Dhcp) {
        $lines += "DHCP scope     : $($State.Dhcp.ScopeName) [$($State.Dhcp.Start) - $($State.Dhcp.End)]"
        $lines += "Mask / GW      : $($State.Dhcp.Mask) / $($State.Dhcp.Router)"
    }
    $lines += '----------------------------------------------------'
    $lines += "Full log: $($Script:LogFile)"
    $lines += '===================================================='
    try { Set-Content -Path $file -Value $lines -Encoding UTF8; Write-Log "Report written: $file" 'OK' }
    catch { Write-Log "Could not write the report: $($_.Exception.Message)" 'WARN' }
}

function Get-ThankYouMessage {
    @"
Installation completed successfully!

Thank you for using AutoDC.

   Author: Taeckens.M
   GitHub: github.com/aractuse

----------------------------------------------------
Be sure to check out ADFlow, my other tool:
automated creation of Active Directory objects
(users, groups, OUs...) from a simple file.

Also available on: github.com/aractuse
----------------------------------------------------
"@
}

function Show-ThankYou {
    [System.Windows.Forms.MessageBox]::Show((Get-ThankYouMessage), "Thank you for using AutoDC",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

# ===========================================================================
#  PROMOTE PHASE
# ===========================================================================
function Invoke-PromotePhase {
    Write-Log "=== PROMOTE PHASE: promotion after rename (current name: $env:COMPUTERNAME) ==="
    $state = Get-State
    if (-not $state -or -not $state.Adds) { Write-Log 'Invalid state for promotion, aborting.' 'ERROR'; Unregister-ResumeTask; return }

    $dsrm = Unprotect-Secret $state.Secrets.Dsrm
    $domPwd = if ($state.Secrets.DomainPwd) { Unprotect-Secret $state.Secrets.DomainPwd } else { '' }

    $adds = [pscustomobject]@{
        NewForest = $state.Adds.NewForest; DomainFqdn = $state.Adds.DomainFqdn; NetBIOS = $state.Adds.NetBIOS
        FuncLevel = $state.Adds.FuncLevel; SiteName = $state.Adds.SiteName
        DomainUser = $state.Adds.DomainUser; DomainPwd = $domPwd; DsrmPassword = $dsrm
        InstallDns = $state.Adds.InstallDns; GlobalCatalog = $state.Adds.GlobalCatalog; Rodc = $state.Adds.Rodc
        CreateDnsDelegation = $state.Adds.CreateDnsDelegation
        DatabasePath = $state.Adds.DatabasePath; LogPath = $state.Adds.LogPath; SysvolPath = $state.Adds.SysvolPath
    }

    # After the promotion reboot, the resume task must point to Configure
    Register-ResumeTask -NextPhase Configure
    # Wipe secrets from the state file (loaded into memory)
    $state.Secrets = $null
    Save-State -State $state

    try {
        $installDns = if ($null -ne $adds.InstallDns) { $adds.InstallDns } else { $state.Roles.DNS }
        Invoke-Promotion -Adds $adds -InstallDns:$installDns
        # Success: Install-ADDS* triggers the reboot -> Configure phase.
    } catch {
        Write-Log "Promotion failed: $($_.Exception.Message)" 'ERROR'
        Write-ErrorReport ("Domain controller promotion failed.`r`n{0}`r`n`r`nThe server was renamed but is NOT a domain controller. The automatic tasks were removed to avoid a reboot loop." -f $_.Exception.Message)
        Unregister-ResumeTask
        Remove-Item -Path $Script:StateFile -Force -ErrorAction SilentlyContinue
    } finally { $dsrm = $null; $domPwd = $null; $adds = $null }
}

# ===========================================================================
#  CONFIGURE PHASE
# ===========================================================================
function Invoke-ConfigurePhase {
    Write-Log '=== CONFIGURE PHASE: post-reboot configuration ==='
    $state = Get-State
    if (-not $state) { Write-Log 'No state file, aborting.' 'ERROR'; Unregister-ResumeTask; return }

    if ($state.Adds) {
        # Attempt counter: avoid an infinite loop if AD never comes up (failed promotion)
        $maxAttempts = 5
        $attempts = [int]$state.ConfigureAttempts + 1
        $state | Add-Member -NotePropertyName ConfigureAttempts -NotePropertyValue $attempts -Force
        Save-State -State $state

        if (-not (Wait-ForActiveDirectory)) {
            if ($attempts -ge $maxAttempts) {
                Write-Log "AD still unavailable after $attempts attempts, aborting." 'ERROR'
                Write-ErrorReport "Active Directory is not available after $attempts reboots. The promotion probably failed. The automatic tasks were removed."
                Unregister-ResumeTask
                Remove-Item -Path $Script:StateFile -Force -ErrorAction SilentlyContinue
            } else {
                Write-Log "AD unavailable (attempt $attempts/$maxAttempts), retrying at next startup." 'WARN'
            }
            return
        }
    }
    if ($state.Dns)  {
        Set-DnsForwarders -Forwarders $state.Dns.Forwarders
        if ($state.Dns.CreateReverseZone -and $state.Adds) {
            Set-ReverseDnsZone -Ip $state.PrimaryIp -Prefix ([int]$state.PrimaryPrefix)
        } elseif ($state.Dns.CreateReverseZone) {
            Write-Log 'Reverse DNS zone requires ADDS (DNS role only), skipped.' 'WARN'
        }
    }
    # NTP time source on the PDC (new forest only)
    if ($state.Adds -and $state.Adds.NewForest -and $state.Adds.ConfigureNtp) {
        Set-NtpTimeSource -NtpServers $state.Adds.NtpServers
    }
    # AD Recycle Bin (new forest only)
    if ($state.Adds -and $state.Adds.NewForest -and $state.Adds.EnableRecycleBin) {
        Enable-AdRecycleBin
    }
    if ($state.Dhcp) {
        if ($state.Adds) {
            $fqdn = "$env:COMPUTERNAME.$($state.Adds.DomainFqdn)"
            Set-DhcpConfiguration -Dhcp $state.Dhcp -ServerFqdn $fqdn -ServerIp $state.PrimaryIp
        } else { Set-StandaloneDhcp -Dhcp $state.Dhcp }
    }
    Write-CompletionReport -State $state
    Unregister-ResumeTask
    Remove-Item -Path $Script:StateFile -Force -ErrorAction SilentlyContinue
    Write-Log '=== Installation complete ===' 'OK'
}

# ===========================================================================
#  SUMMARY (text)
# ===========================================================================
function Build-SummaryText {
    param($Data)
    $rename = $Data.Rename; $network = $Data.Network; $roles = $Data.Roles
    $adds = $Data.Adds; $dns = $Data.Dns; $dhcp = $Data.Dhcp

    $sb = New-Object System.Text.StringBuilder
    if ($rename.Rename) { [void]$sb.AppendLine("SERVER NAME: $env:COMPUTERNAME -> $($rename.NewName)  (reboot before promotion)") }
    else { [void]$sb.AppendLine("SERVER NAME: $env:COMPUTERNAME (unchanged)") }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('NETWORK:')
    foreach ($n in $network) {
        $nm = if ($n.NewName -ne $n.Name) { "$($n.Name) -> $($n.NewName)" } else { $n.Name }
        if ($n.Static) { [void]$sb.AppendLine(("  - {0}: {1}/{2}  GW={3}  DNS={4}" -f $nm, $n.Ip, $n.Prefix, $n.Gateway, ($n.Dns -join ', '))) }
        else { [void]$sb.AppendLine("  - ${nm}: IP unchanged") }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("ROLES: ADDS=$($roles.ADDS)  DNS=$($roles.DNS)  DHCP=$($roles.DHCP)")
    if ($adds) {
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('ADDS:')
        [void]$sb.AppendLine("  Type      : $(if ($adds.NewForest) { 'New forest' } else { 'Additional DC' })")
        [void]$sb.AppendLine("  Domain    : $($adds.DomainFqdn)")
        if ($adds.NewForest) {
            [void]$sb.AppendLine("  NetBIOS   : $($adds.NetBIOS)")
            [void]$sb.AppendLine("  Level     : $($adds.FuncLevel)")
        } else {
            [void]$sb.AppendLine("  Site      : $($adds.SiteName)")
            [void]$sb.AppendLine("  Account   : $($adds.DomainUser)")
            [void]$sb.AppendLine("  GC / RODC : $($adds.GlobalCatalog) / $($adds.Rodc)")
        }
        [void]$sb.AppendLine("  DNS server: $($adds.InstallDns)")
        [void]$sb.AppendLine("  DSRM      : $(if ($adds.DsrmRandom) { 'random (written to Desktop)' } else { 'set manually' })")
    }
    if ($dns)  { [void]$sb.AppendLine(''); [void]$sb.AppendLine("DNS forwarders: $($dns.Forwarders -join ', ')") }
    if ($dhcp) {
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('DHCP:')
        [void]$sb.AppendLine("  Scope     : $($dhcp.ScopeName)")
        [void]$sb.AppendLine("  Range     : $($dhcp.Start) - $($dhcp.End)")
        [void]$sb.AppendLine("  Mask      : $($dhcp.Mask)")
        [void]$sb.AppendLine("  Router    : $($dhcp.Router)")
        [void]$sb.AppendLine("  DNS       : $($dhcp.Dns -join ', ')")
        [void]$sb.AppendLine("  Domain    : $($dhcp.DnsDomain)")
        [void]$sb.AppendLine("  Lease     : $($dhcp.LeaseDays) days")
    }

    $reboots = 0
    if ($rename.Rename) { $reboots++ }
    if ($roles.ADDS)    { $reboots++ }
    $warning = switch ($reboots) {
        0 { 'No reboot required.' }
        1 { 'The server will reboot automatically once.' }
        default { 'The server will reboot automatically TWICE (rename, then promotion).' }
    }
    [pscustomobject]@{ Text = $sb.ToString(); Warning = $warning; IsError = ($reboots -gt 0) }
}

# ===========================================================================
#  INTERACTIVE PHASE: collect (single window) + launch
# ===========================================================================
function Invoke-InteractivePhase {
    Write-Log '=== PHASE 1: interactive collection ==='
    if ($Script:DebugMode) { Write-Log '[DEBUG] Debug mode active: confirmation before every deployment step.' }

    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.ProductType -eq 1) {
        [System.Windows.Forms.MessageBox]::Show('This script must run on a Windows Server edition.', 'Incompatible', 'OK', 'Error') | Out-Null
        return
    }
    if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) {
        if (-not (Confirm-YesNo 'This server is already a domain controller. Continue anyway?')) { return }
    }

    # --- Single tabbed window: everything is entered at once ---
    $data = Show-MainWindow
    if ($null -eq $data) { Write-Log 'Cancelled.'; return }

    $rename = $data.Rename; $network = $data.Network; $roles = $data.Roles
    $adds = $data.Adds; $dns = $data.Dns; $dhcp = $data.Dhcp
    $primary = $network | Where-Object Static | Select-Object -First 1
    $primaryIp = $(if ($primary) { $primary.Ip } else { $null })
    $primaryPrefix = $(if ($primary) { $primary.Prefix } else { $null })

    Write-VerboseInfo ("Rename: " + $(if ($rename.Rename) { "$env:COMPUTERNAME -> $($rename.NewName)" } else { 'unchanged' }))
    Write-VerboseInfo ("Roles: ADDS=$($roles.ADDS) DNS=$($roles.DNS) DHCP=$($roles.DHCP)")

    # --- Execution ---
    Write-Log 'Starting the installation...'
    Set-NetworkConfiguration -Network $network
    Install-Roles -Roles $roles
    if ($data.AllowPing) { Set-PingFirewall }

    # =====================  NO-ADDS CASE  =====================
    if (-not $roles.ADDS) {
        if ($rename.Rename) {
            $state = [pscustomobject]@{ Roles = $roles; Adds = $null; Dns = $dns; Dhcp = $dhcp; PrimaryIp = $primaryIp; PrimaryPrefix = $primaryPrefix; NewName = $rename.NewName }
            Save-State -State $state
            Register-ResumeTask -NextPhase Configure
            Register-ViewerTask
            Confirm-DeployStep "Rename the server to '$($rename.NewName)' and reboot"
            Rename-Computer -NewName $rename.NewName -Force -ErrorAction Stop
            [System.Windows.Forms.MessageBox]::Show("The server will be renamed to '$($rename.NewName)' and reboot.`r`n`r`nThe DNS/DHCP configuration will then finish automatically.", 'Reboot', 'OK', 'Information') | Out-Null
            Restart-Computer -Force
            return
        }
        if ($dns -and (Get-Service DNS -ErrorAction SilentlyContinue)) {
            Set-DnsForwarders -Forwarders $dns.Forwarders
            if ($dns.CreateReverseZone) { Write-Log 'Reverse DNS zone requires ADDS (DNS role only), skipped.' 'WARN' }
        }
        if ($dhcp) { Set-StandaloneDhcp -Dhcp $dhcp }
        Write-CompletionReport -State ([pscustomobject]@{ Adds = $null; Dns = $dns; Dhcp = $dhcp; PrimaryIp = $primaryIp })
        Write-Log '=== Installation complete ===' 'OK'
        Show-ThankYou
        Read-Host "`nPress Enter to close this window"
        return
    }

    # =====================  ADDS CASE  =====================
    Write-DsrmFile -Adds $adds
    $stateBase = @{
        Roles = $roles
        Adds  = [pscustomobject]@{
            NewForest = $adds.NewForest; DomainFqdn = $adds.DomainFqdn; NetBIOS = $adds.NetBIOS
            FuncLevel = $adds.FuncLevel; SiteName = $adds.SiteName; DomainUser = $adds.DomainUser
            InstallDns = $adds.InstallDns; GlobalCatalog = $adds.GlobalCatalog; Rodc = $adds.Rodc
            CreateDnsDelegation = $adds.CreateDnsDelegation
            DatabasePath = $adds.DatabasePath; LogPath = $adds.LogPath; SysvolPath = $adds.SysvolPath
            ConfigureNtp = $adds.ConfigureNtp; NtpServers = $adds.NtpServers
            EnableRecycleBin = $adds.EnableRecycleBin
        }
        Dns = $dns; Dhcp = $dhcp; PrimaryIp = $primaryIp; PrimaryPrefix = $primaryPrefix; NewName = $rename.NewName
    }

    if ($rename.Rename) {
        # Rename -> reboot -> Promote -> reboot -> Configure. Secrets encrypted with machine DPAPI.
        $stateBase.Secrets = [pscustomobject]@{
            Dsrm      = Protect-Secret $adds.DsrmPassword
            DomainPwd = $(if ($adds.NewForest) { '' } else { Protect-Secret $adds.DomainPwd })
        }
        Save-State -State ([pscustomobject]$stateBase)
        Register-ResumeTask -NextPhase Promote
        Register-ViewerTask
        Confirm-DeployStep "Rename the server to '$($rename.NewName)' and reboot (promotion after reboot)"
        Rename-Computer -NewName $rename.NewName -Force -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show("The server will be renamed to '$($rename.NewName)' and reboot.`r`n`r`nThe promotion to domain controller, then the DNS/DHCP configuration, will run automatically (a second reboot will occur).", 'Rename and reboot', 'OK', 'Information') | Out-Null
        Restart-Computer -Force
        return
    }

    # No rename: immediate promotion (DSRM used right away, never written to disk)
    Save-State -State ([pscustomobject]$stateBase)
    if ($roles.DNS -or $roles.DHCP) { Register-ResumeTask -NextPhase Configure; Register-ViewerTask }
    [System.Windows.Forms.MessageBox]::Show("Roles installed and network configured.`r`n`r`nThe server will now be promoted to domain controller and REBOOT automatically.`r`n`r`nThe DNS/DHCP configuration will finish on its own after the reboot.", 'Promotion in progress', 'OK', 'Information') | Out-Null
    Invoke-Promotion -Adds $adds -InstallDns:$adds.InstallDns
}

# ===========================================================================
#  ENTRY POINT
# ===========================================================================
try {
    Initialize-WinForms   # also required for Confirm-DeployStep / MessageBox in the interactive phase
    switch ($Phase) {
        'Promote'   { Invoke-PromotePhase }
        'Configure' { Invoke-ConfigurePhase }
        default     { Invoke-InteractivePhase }
    }
} catch {
    Write-Log "FATAL ERROR: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    if ($Phase -eq 'Interactive') {
        try {
            [System.Windows.Forms.MessageBox]::Show("An error occurred:`r`n$($_.Exception.Message)`r`n`r`nSee the log: $($Script:LogFile)", 'Error', 'OK', 'Error') | Out-Null
        } catch { }
    }
}
