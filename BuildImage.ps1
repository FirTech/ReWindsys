#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    ReWindsys WimFlow 系统镜像封装脚本
.DESCRIPTION
    将原始 Windows ISO 封装为包含 Admin 和 NewAccount 两个卷的定制 WIM/ESD，可选导出为可启动 ISO。
.PARAMETER ISOPath
    Windows ISO 文件路径，脚本自动完成挂载与卸载。
.PARAMETER ISODrive
    已手动挂载的 ISO 盘符，如 "G" 或 "G:"（适用于物理光驱或已挂载场景）。
.PARAMETER ImageIndex
    要定制的 WIM 镜像索引，默认 1。
.PARAMETER OutputDir
    最终输出目录（必填）。
.PARAMETER AsESD
    将输出 WIM 转换为 ESD 格式（Recovery 压缩，体积更小）。
.PARAMETER ExportISO
    同时打包为可启动 ISO（需要 utils\oscdimg\oscdimg.exe）。
.PARAMETER WorkDir
    临时工作目录，默认为 $env:TEMP\WimFlow_yyyyMMdd_HHmmss。
.PARAMETER KeepWorkDir
    调试模式：构建结束后保留工作目录中的中间产物。
.EXAMPLE
    .\BuildImage.ps1 -ISOPath "D:\Win10_22H2.iso" -ImageIndex 1 -OutputDir ".\Output"
.EXAMPLE
    .\BuildImage.ps1 -ISOPath "D:\Win10_22H2.iso" -ImageIndex 1 -OutputDir ".\Output" -AsESD -ExportISO
.EXAMPLE
    .\BuildImage.ps1 -ISODrive "G:" -ImageIndex 1 -OutputDir ".\Output"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'ISOFile')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ISOPath,

    [Parameter(Mandatory, ParameterSetName = 'MountedDrive')]
    [string]$ISODrive,

    [int]$ImageIndex = 1,

    [Parameter(Mandatory)]
    [string]$OutputDir,

    [switch]$AsESD,
    [switch]$ExportISO,

    [string]$WorkDir,
    [switch]$KeepWorkDir
)

$ErrorActionPreference = 'Stop'
$ScriptRoot  = $PSScriptRoot
$FilesRoot   = Join-Path $ScriptRoot 'files'

# ─────────────────────────────────────────────────────────────────────────────
# 工具函数
# ─────────────────────────────────────────────────────────────────────────────

function Write-Phase {
    param([string]$Msg)
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host "  $Msg" -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
}

function Write-Step  { param([string]$Msg) Write-Host "  >> $Msg" -ForegroundColor Yellow }
function Write-Done  { param([string]$Msg) Write-Host "  OK $Msg" -ForegroundColor Green }
function Write-Skip  { param([string]$Msg) Write-Host "  -- $Msg" -ForegroundColor DarkGray }

function Resolve-DriveLetter {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "ISO 盘符不能为空"
    }

    $normalized = $Raw.Trim().ToUpper()
    $match = [regex]::Match($normalized, '[A-Z]')
    if (-not $match.Success) {
        throw "无效的 ISO 盘符参数: $Raw"
    }

    $drive = "{0}:" -f $match.Value
    if (-not (Test-Path "$drive\")) {
        throw "指定的 ISO 盘符不存在或不可访问: $drive"
    }

    return $drive
}

function Build-VolumeName {
    param([string]$Prefix)

    switch ($Prefix) {
        'Admin'      { return 'Admin|Administrator User' }
        'NewAccount' { return 'NewAccount|New Account 新建账户' }
    }
}

# ── 公共封装步骤 ──────────────────────────────────────────────────────────────

function Remove-AppxList {
    param([string]$MountPath, [string]$ListFile)

    $names    = Get-Content $ListFile |
                Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }
    $packages = Get-AppxProvisionedPackage -Path $MountPath

    foreach ($name in $names) {
        $pkg = $packages | Where-Object { $_.PackageName -like "*$name*" }
        if ($pkg) {
            Write-Step "删除 APPX: $($pkg.PackageName)"
            Remove-AppxProvisionedPackage -Path $MountPath -PackageName $pkg.PackageName |
                Out-Null
        } else {
            Write-Skip "未找到（可能已删除）: $name"
        }
    }
}

function Enable-NetFx35 {
    param([string]$MountPath, [string]$SxsPath)

    Write-Step "启用 .NET Framework 3.5，SXS 源: $SxsPath"
    & dism /Image:"$MountPath" /Enable-Feature /FeatureName:NetFx3 /All `
           /LimitAccess /Source:"$SxsPath"
    if ($LASTEXITCODE -ne 0) { throw "NetFx3 启用失败，退出码: $LASTEXITCODE" }
}

function Add-Drivers {
    param([string]$MountPath, [string]$DriversPath)

    $infFiles = Get-ChildItem $DriversPath -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue
    if (-not $infFiles) {
        Write-Skip "drivers 目录中无 .inf 文件，跳过驱动注入"
        return
    }

    Write-Step "注入驱动: $DriversPath"
    Add-WindowsDriver -Path $MountPath -Driver $DriversPath -Recurse -ForceUnsigned |
        Out-Null
}

function Copy-CommonFiles {
    param([string]$MountPath, [string]$FilesRoot)

    Write-Step "复制 Windsys_Setup → $MountPath\"
    Copy-Item "$FilesRoot\Windsys_Setup" "$MountPath\" -Recurse -Force

    Write-Step "复制 WSHub → $MountPath\Program Files\"
    Copy-Item "$FilesRoot\WSHub" "$MountPath\Program Files" -Recurse -Force

    Write-Step "复制 Windsys.ini → $MountPath\Windows\"
    Copy-Item "$FilesRoot\patch\Windsys.ini" "$MountPath\Windows\" -Force
}

function Import-OfflineRegistry {
    param([string]$MountPath, [string]$RegFile)

    $hive     = "$MountPath\Windows\System32\config\SYSTEM"
    $configDir = "$MountPath\Windows\System32\config"
    $mountKey = 'HKLM\Tmp_SYSTEM'

    Write-Step "挂载注册表 Hive: $hive → $mountKey"
    & reg load $mountKey $hive
    if ($LASTEXITCODE -ne 0) { throw "reg load 失败，退出码: $LASTEXITCODE" }

    try {
        Write-Step "导入注册表: $RegFile"
        & reg import $RegFile
        if ($LASTEXITCODE -ne 0) { throw "reg import 失败，退出码: $LASTEXITCODE" }
    } finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()

        $unloaded = $false
        for ($i = 0; $i -lt 3; $i++) {
            & reg unload $mountKey | Out-Null
            if ($LASTEXITCODE -eq 0) { $unloaded = $true; break }
            Start-Sleep -Seconds 2
        }
        if (-not $unloaded) {
            Write-Warning "reg unload 失败，请手动执行: reg unload $mountKey"
        } else {
            Write-Done "注册表 Hive 已卸载"

            $staleLogs = Get-ChildItem -Path $configDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '*.LOG*' -or $_.Name -like '*{*}*' }

            if ($staleLogs) {
                Write-Step "删除注册表日志与残留文件: $configDir"
                $staleLogs | Remove-Item -Force -ErrorAction SilentlyContinue
            } else {
                Write-Skip "未发现需要清理的注册表日志文件"
            }
        }
    }
}

function Invoke-CommonSteps {
    param([string]$MountPath, [string]$IsoDrive, [string]$FilesRoot)

    Remove-AppxList        -MountPath $MountPath -ListFile "$FilesRoot\config\AppxRemoveList.txt"
    Enable-NetFx35         -MountPath $MountPath -SxsPath "$IsoDrive\sources\sxs"
    Add-Drivers            -MountPath $MountPath -DriversPath "$FilesRoot\drivers"
    Copy-CommonFiles       -MountPath $MountPath -FilesRoot $FilesRoot
    Import-OfflineRegistry -MountPath $MountPath -RegFile "$FilesRoot\registry\WRDR_Takeover.reg"
}

# ── 镜像导出 ──────────────────────────────────────────────────────────────────

function Export-WimVolume {
    param(
        [string]$SourceWim,
        [int]   $SourceIndex,
        [string]$DestFile,
        [string]$VolumeName,
        [bool]  $UseESD
    )

    Write-Step "导出卷: $VolumeName"
    $compress = if ($UseESD) { 'recovery' } else { 'max' }

    & dism /Export-Image `
           /SourceImageFile:"$SourceWim" `
           /SourceIndex:$SourceIndex `
           /DestinationImageFile:"$DestFile" `
           /DestinationName:"$VolumeName" `
           /Compress:$compress

    if ($LASTEXITCODE -ne 0) { throw "镜像导出失败，退出码: $LASTEXITCODE" }
}

# ── 可启动 ISO 打包 ───────────────────────────────────────────────────────────

function Build-BootableISO {
    param(
        [string]$IsoDrive,
        [string]$InstallFile,
        [string]$WorkDir,
        [string]$OutputDir
    )

    $oscdimg = Join-Path $ScriptRoot 'utils\oscdimg\oscdimg.exe'
    if (-not (Test-Path $oscdimg)) { throw "找不到 oscdimg.exe: $oscdimg" }

    $isoRoot = "$IsoDrive\"
    $bootFiles = @('boot\etfsboot.com', 'efi\microsoft\boot\efisys.bin')
    foreach ($bootFile in $bootFiles) {
        $sourceBootFile = Join-Path $isoRoot $bootFile
        if (-not (Test-Path -LiteralPath $sourceBootFile -PathType Leaf)) {
            throw "源 ISO 缺少引导文件: $sourceBootFile"
        }
    }

    $staging = Join-Path $WorkDir 'iso_staging'
    $srcDir  = Join-Path $staging 'sources'
    New-Item $srcDir -ItemType Directory -Force | Out-Null

    Write-Step "复制 ISO 引导文件"
    Get-ChildItem -LiteralPath $isoRoot -Force | Where-Object { $_.Name -ne 'sources' } | ForEach-Object {
        Copy-Item $_.FullName $staging -Recurse -Force
    }

    Write-Step "复制 sources 目录（排除原 install 文件）"
    Get-ChildItem -LiteralPath (Join-Path $isoRoot 'sources') -Force |
        Where-Object { $_.Name -notmatch '^install\.(wim|esd)$' } |
        ForEach-Object { Copy-Item $_.FullName $srcDir -Recurse -Force }

    Write-Step "复制封装好的 install 文件"
    Copy-Item $InstallFile $srcDir -Force

    foreach ($bootFile in $bootFiles) {
        $stagedBootFile = Join-Path $staging $bootFile
        if (-not (Test-Path -LiteralPath $stagedBootFile -PathType Leaf)) {
            throw "ISO 暂存目录缺少引导文件: $stagedBootFile"
        }
    }

    $isoName = "ReWindsys_Custom_$(Get-Date -Format yyMMdd).iso"
    $isoOut  = Join-Path $OutputDir $isoName
    Write-Step "调用 oscdimg 生成 ISO: $isoOut"

    $bootData = '2#p0,e,b{0}\boot\etfsboot.com#pEF,e,b{1}\efi\microsoft\boot\efisys.bin' `
                -f $staging, $staging

    & $oscdimg -m -o -h -u2 -udfver102 "-bootdata:$bootData" $staging $isoOut
    if ($LASTEXITCODE -ne 0) { throw "oscdimg 失败，退出码: $LASTEXITCODE" }

    Write-Done "ISO 已生成: $isoOut"
}

# ── 清理挂载点 ────────────────────────────────────────────────────────────────

function Dismount-AllMounts {
    param([string[]]$Paths)

    $mounted = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue
    foreach ($p in $Paths) {
        $m = $mounted | Where-Object { $_.Path -eq $p }
        if ($m) {
            Write-Host "  [清理] 强制卸载: $p" -ForegroundColor DarkYellow
            Dismount-WindowsImage -Path $p -Discard -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────────────────────

if (-not $WorkDir) {
    $WorkDir = Join-Path $env:TEMP "WimFlow_$(Get-Date -Format yyyyMMdd_HHmmss)"
}

$resolvedIsoDrive = $null
$isoMountedByUs   = $false

# 挂载点路径集合（供 finally 清理使用）
$mntBase    = Join-Path $WorkDir 'mount_base'
$mntVariant = Join-Path $WorkDir 'mount_variant'
$wimDir     = Join-Path $WorkDir 'wim'

# ── 阶段 1：前置验证 ──────────────────────────────────────────────────────────
Write-Phase "阶段 1/6：前置验证"

$requiredFiles = @(
    "$FilesRoot\config\AppxRemoveList.txt",
    "$FilesRoot\registry\WRDR_Takeover.reg",
    "$FilesRoot\Windsys_Setup\WTDR\Takeover.cmd",
    "$FilesRoot\Windsys_Setup\WTDR\Sleep.vbs",
    "$FilesRoot\patch\Windsys.ini",
    "$FilesRoot\Windsys_Setup",
    "$FilesRoot\WSHub",
    "$FilesRoot\subImage\Admin\Panther\unattend.xml",
    "$FilesRoot\subImage\NewAccount\Panther\unattend.xml",
    "$FilesRoot\subImage\NewAccount\WTDR_Config.ini"
)
foreach ($f in $requiredFiles) {
    if (-not (Test-Path $f)) { throw "缺少必要文件/目录: $f" }
    Write-Done $f
}

foreach ($d in @($wimDir, $mntBase, $mntVariant)) {
    New-Item $d -ItemType Directory -Force | Out-Null
}
New-Item $OutputDir -ItemType Directory -Force | Out-Null
Write-Done "工作目录: $WorkDir"

try {
    # ── 阶段 2：挂载 ISO & 提取元数据 ────────────────────────────────────────
    Write-Phase "阶段 2/6：挂载 ISO & 提取元数据"

    if ($PSCmdlet.ParameterSetName -eq 'ISOFile') {
        Write-Step "挂载 ISO: $ISOPath"
        Mount-DiskImage -ImagePath $ISOPath | Out-Null
        $isoMountedByUs = $true
        Start-Sleep -Seconds 2
        $driveLetter = (Get-DiskImage -ImagePath $ISOPath | Get-Volume).DriveLetter
        if ([string]::IsNullOrWhiteSpace($driveLetter)) {
            throw "ISO 挂载成功但无法获取盘符，请检查 ISO 文件是否有效"
        }
        $resolvedIsoDrive = Resolve-DriveLetter $driveLetter
    } else {
        $resolvedIsoDrive = Resolve-DriveLetter $ISODrive
    }
    Write-Done "ISO 盘符: $resolvedIsoDrive"

    $sourceWim = "$resolvedIsoDrive\sources\install.wim"
    if (-not (Test-Path $sourceWim)) {
        $sourceWim = "$resolvedIsoDrive\sources\install.esd"
        if (-not (Test-Path $sourceWim)) {
            throw "在 $resolvedIsoDrive\sources\ 中找不到 install.wim 或 install.esd"
        }
        Write-Step "源文件: install.esd"
    } else {
        Write-Step "源文件: install.wim"
    }

    # ── 阶段 3：公共步骤 → base.wim ───────────────────────────────────────────
    Write-Phase "阶段 3/6：公共步骤 (Base)"

    $baseWim    = Join-Path $wimDir 'base.wim'
    $variantWim = Join-Path $wimDir 'variant.wim'
    Write-Step "导出源 WIM 索引 $ImageIndex → base.wim (Fast 压缩)"
    Export-WindowsImage -SourceImagePath $sourceWim -SourceIndex $ImageIndex `
        -DestinationImagePath $baseWim -DestinationName 'Base' `
        -CompressionType Fast | Out-Null

    Write-Step "挂载 base.wim"
    Mount-WindowsImage -ImagePath $baseWim -Index 1 -Path $mntBase | Out-Null

    try {
        Invoke-CommonSteps -MountPath $mntBase -IsoDrive $resolvedIsoDrive -FilesRoot $FilesRoot
    } catch {
        Write-Host "  [错误] 公共步骤失败，正在放弃挂载..." -ForegroundColor Red
        Dismount-WindowsImage -Path $mntBase -Discard -ErrorAction SilentlyContinue | Out-Null
        throw
    }

    Write-Step "保存 base.wim"
    Dismount-WindowsImage -Path $mntBase -Save | Out-Null
    Write-Done "Base 公共步骤完成"

    # ── 阶段 4：Admin 卷 ──────────────────────────────────────────────────────
    Write-Phase "阶段 4/6：Admin 卷"

    $ext        = if ($AsESD) { 'esd' } else { 'wim' }
    $outputFile = Join-Path $OutputDir "install.$ext"
    if (Test-Path $outputFile) { Remove-Item $outputFile -Force }

    $adminName = Build-VolumeName -Prefix 'Admin'
    $naName    = Build-VolumeName -Prefix 'NewAccount'

    if (Test-Path $variantWim) {
        Write-Step "删除旧的 variant.wim"
        Remove-Item $variantWim -Force
    }

    Write-Step "复制 base.wim → variant.wim"
    Copy-Item $baseWim $variantWim -Force

    Write-Step "挂载 variant.wim (Admin)"
    Mount-WindowsImage -ImagePath $variantWim -Index 1 -Path $mntVariant | Out-Null

    try {
        Write-Step "复制 Admin unattend.xml"
        $destPanther = "$mntVariant\Windows\Panther"
        New-Item $destPanther -ItemType Directory -Force | Out-Null
        Copy-Item "$FilesRoot\subImage\Admin\Panther\unattend.xml" $destPanther -Force
    } catch {
        Write-Host "  [错误] Admin 步骤失败，正在放弃挂载..." -ForegroundColor Red
        Dismount-WindowsImage -Path $mntVariant -Discard -ErrorAction SilentlyContinue | Out-Null
        throw
    }

    Write-Step "保存 variant.wim (Admin)"
    Dismount-WindowsImage -Path $mntVariant -Save | Out-Null

    Export-WimVolume -SourceWim $variantWim -SourceIndex 1 `
        -DestFile $outputFile -VolumeName $adminName -UseESD $AsESD.IsPresent
    Remove-Item $variantWim -Force
    Write-Done "Admin 卷处理完成"

    # ── 阶段 5：NewAccount 卷 ─────────────────────────────────────────────────
    Write-Phase "阶段 5/6：NewAccount 卷"

    Write-Step "复制 base.wim → variant.wim"
    Copy-Item $baseWim $variantWim -Force

    Write-Step "挂载 variant.wim (NewAccount)"
    Mount-WindowsImage -ImagePath $variantWim -Index 1 -Path $mntVariant | Out-Null

    try {
        Write-Step "复制 NewAccount unattend.xml"
        $destPanther = "$mntVariant\Windows\Panther"
        New-Item $destPanther -ItemType Directory -Force | Out-Null
        Copy-Item "$FilesRoot\subImage\NewAccount\Panther\unattend.xml" $destPanther -Force

        Write-Step "复制 NewAccount WTDR_Config.ini"
        $destWTDR = "$mntVariant\Windsys_Setup\WTDR"
        if (-not (Test-Path $destWTDR)) { New-Item $destWTDR -ItemType Directory -Force | Out-Null }
        Copy-Item "$FilesRoot\subImage\NewAccount\WTDR_Config.ini" $destWTDR -Force
    } catch {
        Write-Host "  [错误] NewAccount 步骤失败，正在放弃挂载..." -ForegroundColor Red
        Dismount-WindowsImage -Path $mntVariant -Discard -ErrorAction SilentlyContinue | Out-Null
        throw
    }

    Write-Step "保存 variant.wim (NewAccount)"
    Dismount-WindowsImage -Path $mntVariant -Save | Out-Null

    # ── 阶段 6：合并导出 ──────────────────────────────────────────────────────
    Write-Phase "阶段 6/6：合并导出"

    Export-WimVolume -SourceWim $variantWim -SourceIndex 1 `
        -DestFile $outputFile -VolumeName $naName -UseESD $AsESD.IsPresent

    Remove-Item $variantWim -Force
    Remove-Item $baseWim -Force
    Write-Done "NewAccount 卷处理完成"

    Write-Done "镜像输出: $outputFile"

    if ($ExportISO) {
        Write-Phase "附加：打包可启动 ISO"
        Build-BootableISO -IsoDrive $resolvedIsoDrive -InstallFile $outputFile `
            -WorkDir $WorkDir -OutputDir $OutputDir
    }

    # 输出汇总
    Write-Phase "完成！"
    Write-Host "  输出目录: $(Resolve-Path $OutputDir)" -ForegroundColor Green
    Write-Host ''
    Get-WindowsImage -ImagePath $outputFile | ForEach-Object {
        Write-Host ("  [{0}] {1}" -f $_.ImageIndex, $_.ImageName) -ForegroundColor Green
    }

} finally {
    Dismount-AllMounts -Paths @($mntBase, $mntVariant)

    if ($isoMountedByUs) {
        Write-Host "卸载 ISO..." -ForegroundColor DarkGray
        Dismount-DiskImage -ImagePath $ISOPath -ErrorAction SilentlyContinue | Out-Null
    }

    if (-not $KeepWorkDir -and (Test-Path $WorkDir)) {
        Write-Host "清理工作目录: $WorkDir" -ForegroundColor DarkGray
        Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    } elseif ($KeepWorkDir) {
        Write-Host "工作目录已保留: $WorkDir" -ForegroundColor DarkGray
    }
}
