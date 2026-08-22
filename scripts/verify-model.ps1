<#
.SYNOPSIS
    校验手动下载的模型目录是否完整正确。

.DESCRIPTION
    手动从 HuggingFace 下载多文件模型时有三种常见失败,而且都不会自己报错:

      1. 漏文件 —— 22 个文件少下一个,加载时才报错,且错误信息通常晦涩。
      2. 下到 LFS pointer —— 大文件若走了错误的 URL,得到的是一个几百字节的
         文本文件(内容形如 "version https://git-lfs.github.com/spec/v1"),
         而不是真实权重。文件确实存在,大小完全不对。
      3. 下到 HTML 错误页 —— 用 blob/ 而不是 resolve/ 的链接时,得到的是网页。

    本脚本按内置的精确字节数逐个核对,并额外检查文件头以识别 LFS pointer
    与 HTML。字节数来自 HuggingFace 仓库的 tree API,已实测。

.PARAMETER Model
    要校验的模型。

.PARAMETER Path
    模型目录。默认 runtime\models\<模型目录名>。

.EXAMPLE
    .\scripts\verify-model.ps1 -Model gemma4-e2b

.EXAMPLE
    .\scripts\verify-model.ps1 -Model gemma4-e2b -Path D:\downloads\gemma4
    校验任意目录,不要求已放到 runtime\models 下。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('gemma4-e2b')]
    [string] $Model,

    [string] $Path = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# 期望清单:文件名 => 精确字节数
# 数据来源:https://huggingface.co/api/models/<repo>/tree/main(实测)
# ---------------------------------------------------------------------------

$Catalog = @{
    'gemma4-e2b' = @{
        Repo = 'OpenVINO/gemma-4-E2B-it-int4-ov'
        Dir  = 'gemma-4-E2B-it-int4-ov'
        # Required = $true 的文件缺失即判失败;$false 的仅提示
        Files = @(
            @{ Name = 'openvino_language_model.bin';                  Size = 1379621905; Required = $true }
            @{ Name = 'openvino_language_model.xml';                  Size = 4012442;    Required = $true }
            @{ Name = 'openvino_text_embeddings_per_layer_model.bin';  Size = 2349334608; Required = $true }
            @{ Name = 'openvino_text_embeddings_per_layer_model.xml';  Size = 17927;      Required = $true }
            @{ Name = 'openvino_text_embeddings_model.bin';           Size = 403177480;  Required = $true }
            @{ Name = 'openvino_text_embeddings_model.xml';           Size = 7119;       Required = $true }
            @{ Name = 'openvino_vision_embeddings_model.bin';         Size = 169024052;  Required = $true }
            @{ Name = 'openvino_vision_embeddings_model.xml';         Size = 2028930;    Required = $true }
            @{ Name = 'openvino_tokenizer.bin';                       Size = 17270328;   Required = $true }
            @{ Name = 'openvino_tokenizer.xml';                       Size = 42753;      Required = $true }
            @{ Name = 'openvino_detokenizer.bin';                     Size = 4413547;    Required = $true }
            @{ Name = 'openvino_detokenizer.xml';                     Size = 27378;      Required = $true }
            @{ Name = 'tokenizer.json';                               Size = 32169626;   Required = $true }
            @{ Name = 'tokenizer_config.json';                        Size = 2712;       Required = $true }
            @{ Name = 'config.json';                                  Size = 4983;       Required = $true }
            @{ Name = 'generation_config.json';                       Size = 203;        Required = $true }
            @{ Name = 'openvino_config.json';                         Size = 1424;       Required = $true }
            @{ Name = 'chat_template.jinja';                          Size = 16317;      Required = $true }
            @{ Name = 'preprocessor_config.json';                     Size = 403;        Required = $true }
            @{ Name = 'processor_config.json';                        Size = 1689;       Required = $true }
            @{ Name = 'README.md';                                    Size = 3604;       Required = $false }
            @{ Name = '.gitattributes';                               Size = 1570;       Required = $false }
        )
    }
}

$spec = $Catalog[$Model]

if ($Path -eq '') {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $Path = Join-Path $repoRoot ('runtime\models\' + $spec.Dir)
}

Write-Host ''
Write-Host "校验模型 : $($spec.Repo)" -ForegroundColor Cyan
Write-Host "目录     : $Path" -ForegroundColor Cyan
Write-Host ''

if (-not (Test-Path $Path)) {
    Write-Host "目录不存在:$Path" -ForegroundColor Red
    Write-Host ''
    Write-Host '请先下载模型。链接见 docs\installation.md 第 4.1 节。' -ForegroundColor Yellow
    exit 2
}

# ---------------------------------------------------------------------------
# 逐个核对
# ---------------------------------------------------------------------------

function Test-FileContentKind {
    <#
        读文件头判断内容类型,用来区分「真实权重」与「LFS pointer / HTML 错误页」。
        只看前 200 字节,不加载整个文件 —— 权重文件有 GB 级,不能读进内存。
    #>
    param([string] $FilePath)

    $fs = [System.IO.File]::OpenRead($FilePath)
    try {
        $len   = [Math]::Min(200, $fs.Length)
        $buf   = New-Object byte[] $len
        $null  = $fs.Read($buf, 0, $len)
        $head  = [System.Text.Encoding]::ASCII.GetString($buf)
    } finally {
        $fs.Dispose()
    }

    if ($head -like 'version https://git-lfs*') { return 'LFS_POINTER' }
    if ($head -match '^\s*<(!DOCTYPE|html)')    { return 'HTML' }
    return 'OK'
}

$ok       = 0
$bad      = @()
$missing  = @()
$optMiss  = @()
$totalGot = 0

foreach ($f in $spec.Files) {
    $p = Join-Path $Path $f.Name

    if (-not (Test-Path $p)) {
        if ($f.Required) {
            $missing += $f.Name
            Write-Host ('  [缺失] ' + $f.Name) -ForegroundColor Red
        } else {
            $optMiss += $f.Name
        }
        continue
    }

    $actual = (Get-Item $p).Length
    $totalGot += $actual

    if ($actual -ne $f.Size) {
        $kind = Test-FileContentKind $p
        $why  = switch ($kind) {
            'LFS_POINTER' { '这是 LFS 指针文件,不是真实内容 —— 用了错误的下载方式' }
            'HTML'        { '这是 HTML 网页 —— 应该用 resolve/main 而不是 blob/main' }
            default       { '大小不符,可能下载不完整' }
        }
        $bad += [pscustomobject]@{
            Name = $f.Name; Expected = $f.Size; Actual = $actual; Why = $why
        }
        Write-Host ('  [错误] ' + $f.Name) -ForegroundColor Red
        Write-Host ('         期望 ' + $f.Size + ' 字节,实际 ' + $actual + ' 字节') -ForegroundColor DarkYellow
        Write-Host ('         ' + $why) -ForegroundColor DarkYellow
        continue
    }

    $ok++
    if ($f.Size -gt 1MB) {
        Write-Host ('  [OK]   ' + $f.Name.PadRight(48) + [math]::Round($actual / 1MB, 1).ToString() + ' MB') -ForegroundColor Green
    } else {
        Write-Host ('  [OK]   ' + $f.Name) -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 结论
# ---------------------------------------------------------------------------

$requiredCount = ($spec.Files | Where-Object { $_.Required }).Count

Write-Host ''
Write-Host ('通过 ' + $ok + ' 个文件,合计 ' + [math]::Round($totalGot / 1GB, 2) + ' GB') -ForegroundColor Gray

if ($optMiss.Count -gt 0) {
    Write-Host ('缺少 ' + $optMiss.Count + ' 个可选文件(不影响使用):' + ($optMiss -join ', ')) -ForegroundColor DarkGray
}

Write-Host ''

if ($missing.Count -eq 0 -and $bad.Count -eq 0) {
    Write-Host '模型完整,可以使用。' -ForegroundColor Green
    Write-Host ''
    exit 0
}

Write-Host '校验未通过。' -ForegroundColor Red
if ($missing.Count -gt 0) {
    Write-Host ('  缺失必需文件 ' + $missing.Count + ' 个:') -ForegroundColor Red
    $missing | ForEach-Object { Write-Host ('    ' + $_) -ForegroundColor Red }
}
if ($bad.Count -gt 0) {
    Write-Host ('  内容有问题 ' + $bad.Count + ' 个:') -ForegroundColor Red
    $bad | ForEach-Object { Write-Host ('    ' + $_.Name + ' —— ' + $_.Why) -ForegroundColor Red }
}
Write-Host ''
Write-Host '重新下载对应文件即可,已正确的文件不用重下。' -ForegroundColor Yellow
Write-Host '注意下载 URL 必须是 .../resolve/main/<文件名>,不能是 .../blob/main/<文件名>。' -ForegroundColor Yellow
Write-Host ''
exit 1
