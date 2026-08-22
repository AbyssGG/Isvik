<#
.SYNOPSIS
    获取 Isvik 开发与验证所需的外部依赖(OpenVINO Runtime + Tokenizers 扩展 + LLM 模型)。

.DESCRIPTION
    本脚本只做「下载 + 就位 + 校验」,不改任何系统设置,不写注册表,不装驱动。

    为什么需要这些:
      - OpenVINO GenAI archive 一个包同时提供 OpenVINO Runtime 与 Tokenizers 扩展。
        Tokenizers 扩展(openvino_tokenizers.dll)是加载模型仓库里
        openvino_tokenizer.xml / openvino_detokenizer.xml 的前提 —— 没有它,
        「文本 → token id」这一段就没有着落。
      - archive 来源替换掉当前从 pip 包间接得到的 DLL,使「获取 DLL」这一步
        不再隐含 Python 依赖(见 DEVLOG 第六节 6.3 第 12 条)。
      - 模型使用 OpenVINO 官方预转换的 IR,直接可用,不需要 Python 做模型转换。

    幂等:已存在的产物默认跳过。用 -Force 强制重新获取。

.PARAMETER What
    要获取的内容:
      Runtime  仅 OpenVINO GenAI archive(Runtime + Tokenizers)
      Model    仅 LLM 模型
      All      两者(默认)

.PARAMETER Model
    要下载的模型标识:

    单 IR 的纯文本 LLM(结构简单,适合先打通链路):
      small       OpenVINO/Qwen2.5-1.5B-Instruct-int4-ov      约 886 MB
                  group-wise INT4。用于 CPU / GPU 验证,体积小、下载快。
      npu         OpenVINO/Phi-3.5-mini-instruct-int4-cw-ov   约 1.9 GB
                  channel-wise INT4(-cw-),满足 NPU 对量化格式的要求。
      npu-big     OpenVINO/Qwen3-8B-int4-cw-ov                约 8.8 GB
                  channel-wise INT4。较大,首次 NPU 编译会很慢。

    Gemma 4 多模态(5 个 IR,Apache-2.0,额外工作量见下方 NOTES):
      gemma4-e2b  OpenVINO/gemma-4-E2B-it-int4-ov             约 4.1 GB
      gemma4-e4b  OpenVINO/gemma-4-E4B-it-int4-ov             约 6.1 GB

      both        small + npu(默认,约 2.8 GB)

.PARAMETER Force
    忽略已存在的产物,强制重新下载。

.EXAMPLE
    .\scripts\fetch-deps.ps1
    获取全部(Runtime + small + npu 两个模型)。

.EXAMPLE
    .\scripts\fetch-deps.ps1 -What Runtime
    只补齐 OpenVINO Runtime 与 Tokenizers 扩展。

.EXAMPLE
    .\scripts\fetch-deps.ps1 -What Model -Model small
    只下最小的验证模型。

.EXAMPLE
    .\scripts\fetch-deps.ps1 -What Model -Model gemma4-e2b -TryHuggingFace
    只下 Gemma 4 E2B。

.NOTES
    依赖的外部命令:curl(Windows 自带)、tar(Windows 自带)。
    本机已验证这些全部就绪,脚本仍会在开始前检查并如实报告。

    关于 Gemma 4 的四项额外工作(依据 OpenVINO 2026.3 发布说明的已知问题):

    1. 它由 5 个 IR 组成(language_model / text_embeddings /
       text_embeddings_per_layer / vision_embeddings / tokenizer),需要自行编排。
       Per-Layer Embeddings 要求每层注入额外的 embedding 信号,编排错了输出即为垃圾。
    2. 其 chat template 无法被 OpenVINO GenAI 自带的 Minja 模板引擎解析
       (已知问题 ID 191107,原因是 Minja 不支持相邻字面量字符串拼接)。
       官方变通办法是手动改用旧版模板。
    3. INT4 / INT8 权重压缩版本必须显式把 KV cache group size 设为 64
       才能保持精度(已知问题 ID 186412)。
    4. NPU 支持没有官方声明 —— 发布说明中 Gemma 4 只涉及 CPU / GPU 与
       GenAI 的 SDPA 后端。31B 与 26B-A4B 明确标注为「仅 GPU」。

    因此建议先用 small(单 IR)打通推理链路,再换 Gemma 4:
    这样出问题时能区分「编排写错」与「模型特殊」。
#>

[CmdletBinding()]
param(
    [ValidateSet('All', 'Runtime', 'Model')]
    [string] $What = 'All',

    [ValidateSet('small', 'npu', 'npu-big', 'gemma4-e2b', 'gemma4-e4b', 'both')]
    [string] $Model = 'both',

    # 实际去 HuggingFace 下载模型。
    # 默认关闭:本机实测 huggingface.co 与 hf-mirror.com 均不可达
    # (HTTP 000,连接层面失败)。默认直接下载只会让用户对着一串
    # 超时干等,所以改为默认打印可选路径,确认能访问后再显式开启。
    [switch] $TryHuggingFace,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# 常量:版本与来源全部显式写死,便于复现与审查
# ---------------------------------------------------------------------------

# 该 build 号与本机当前实测的 OpenVINO 版本一致(2026.3.0-22451),
# 因此替换来源不会引起版本漂移。
$OpenVinoVersion = '2026.3'
$GenAiPackage    = 'openvino_genai_windows_2026.3.0.0_x86_64.zip'
$GenAiUrl        = "https://storage.openvinotoolkit.org/repositories/openvino_genai/packages/$OpenVinoVersion/windows/$GenAiPackage"

$HfBase = 'https://huggingface.co'

# 单 IR 的纯文本 LLM 所需文件。
# 刻意逐个列出而不是 git clone 整个仓库:git clone 会在 .git 里额外保存一份
# 副本,等于双倍磁盘占用。
$SingleIrFiles = @(
    'openvino_model.xml'
    'openvino_model.bin'
    'openvino_tokenizer.xml'
    'openvino_tokenizer.bin'
    'openvino_detokenizer.xml'
    'openvino_detokenizer.bin'
    'config.json'
    'generation_config.json'
    'tokenizer_config.json'
    'special_tokens_map.json'
)

# Gemma 4 的文件构成完全不同 —— 它原生多模态,由 5 个 IR 组成:
#   language_model              语言模型主体
#   text_embeddings             文本嵌入
#   text_embeddings_per_layer   逐层嵌入(Per-Layer Embeddings 架构)
#   vision_embeddings           视觉嵌入
#   tokenizer / detokenizer     分词与反分词
# 这套编排在 OpenVINO GenAI 的 VLMPipeline 里是现成的,Isvik 需自行实现。
$Gemma4Files = @(
    'openvino_language_model.xml'
    'openvino_language_model.bin'
    'openvino_text_embeddings_model.xml'
    'openvino_text_embeddings_model.bin'
    'openvino_text_embeddings_per_layer_model.xml'
    'openvino_text_embeddings_per_layer_model.bin'
    'openvino_vision_embeddings_model.xml'
    'openvino_vision_embeddings_model.bin'
    'openvino_tokenizer.xml'
    'openvino_tokenizer.bin'
    'openvino_detokenizer.xml'
    'openvino_detokenizer.bin'
    'config.json'
    'generation_config.json'
    'openvino_config.json'
    'tokenizer_config.json'
    'tokenizer.json'
    'chat_template.jinja'
    'preprocessor_config.json'
    'processor_config.json'
)

$ModelCatalog = @{
    'small' = @{
        Repo     = 'OpenVINO/Qwen2.5-1.5B-Instruct-int4-ov'
        Dir      = 'Qwen2.5-1.5B-Instruct-int4-ov'
        Required = $SingleIrFiles
        Optional = @('tokenizer.json', 'vocab.json', 'merges.txt', 'added_tokens.json')
        SizeMB   = 886
        Purpose  = 'CPU / GPU 验证(单 IR,group-wise INT4,体积小)'
        License  = 'Apache-2.0'
        Note     = '推荐作为第一个跑通的模型:单 IR、chat template 简单'
    }
    'npu' = @{
        Repo     = 'OpenVINO/Phi-3.5-mini-instruct-int4-cw-ov'
        Dir      = 'Phi-3.5-mini-instruct-int4-cw-ov'
        Required = $SingleIrFiles
        Optional = @('tokenizer.json', 'tokenizer.model', 'added_tokens.json', 'openvino_config.json')
        SizeMB   = 1921
        Purpose  = 'NPU 验证(单 IR,channel-wise INT4,满足 NPU 量化要求)'
        License  = 'MIT'
        Note     = ''
    }
    'npu-big' = @{
        Repo     = 'OpenVINO/Qwen3-8B-int4-cw-ov'
        Dir      = 'Qwen3-8B-int4-cw-ov'
        Required = $SingleIrFiles
        Optional = @('tokenizer.json', 'vocab.json', 'merges.txt', 'added_tokens.json', 'openvino_config.json')
        SizeMB   = 9030
        Purpose  = 'NPU 验证(单 IR,channel-wise INT4,较大)'
        License  = 'Apache-2.0'
        Note     = ''
    }
    'gemma4-e2b' = @{
        Repo     = 'OpenVINO/gemma-4-E2B-it-int4-ov'
        Dir      = 'gemma-4-E2B-it-int4-ov'
        Required = $Gemma4Files
        Optional = @('added_tokens.json', 'special_tokens_map.json')
        SizeMB   = 4154
        Purpose  = 'Gemma 4 多模态(5 个 IR,Per-Layer Embeddings)'
        License  = 'Apache-2.0'
        Note     = '见 docs/installation.md 关于 Gemma 4 的四项额外工作'
    }
    'gemma4-e4b' = @{
        Repo     = 'OpenVINO/gemma-4-E4B-it-int4-ov'
        Dir      = 'gemma-4-E4B-it-int4-ov'
        Required = $Gemma4Files
        Optional = @('added_tokens.json', 'special_tokens_map.json')
        SizeMB   = 6154
        Purpose  = 'Gemma 4 多模态,能力更强(5 个 IR)'
        License  = 'Apache-2.0'
        Note     = '见 docs/installation.md 关于 Gemma 4 的四项额外工作'
    }
}

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$RuntimeDir = Join-Path $RepoRoot 'runtime\openvino'
$ModelsDir  = Join-Path $RepoRoot 'runtime\models'
$TempDir    = Join-Path $RepoRoot 'build\deps-tmp'

# ---------------------------------------------------------------------------
# 辅助
# ---------------------------------------------------------------------------

function Write-Step   { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok     { param([string] $Message) Write-Host "    [OK]   $Message" -ForegroundColor Green }
function Write-Skip   { param([string] $Message) Write-Host "    [跳过] $Message" -ForegroundColor DarkGray }
function Write-Warn   { param([string] $Message) Write-Host "    [注意] $Message" -ForegroundColor Yellow }
function Write-Detail { param([string] $Message) Write-Host "    $Message" -ForegroundColor Gray }

function Assert-Command {
    param([string] $Name, [string] $Why)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "缺少必需命令 '$Name'($Why)。请先安装后重试。"
    }
    return $cmd.Source
}

function Test-Reachable {
    <#
        探测站点可达性。

        存在的理由:本机实测 huggingface.co 与 hf-mirror.com 均为 HTTP 000
        (TCP/TLS 连不上,不是 404)。若不预检就直接开始下载,用户会看到
        十几条 curl 逐个失败,而真正的原因(整个站点不可达)被埋在噪声里。
        先探测一次,把「站点不可达」和「某个文件不存在」区分开。
    #>
    param([string] $Url, [int] $TimeoutSec = 15)

    # 局部放宽错误策略。原因:脚本全局设了 $ErrorActionPreference = 'Stop',
    # 而 curl 连接失败时会往 stderr 写诊断信息,PowerShell 会把原生命令的
    # stderr 输出当成 ErrorRecord 并触发终止 —— 于是「探测不可达」这件
    # 完全正常的事会把整个脚本打断。函数内的赋值是局部作用域,退出即恢复。
    $ErrorActionPreference = 'Continue'

    $code = & curl.exe -s -o NUL --max-time $TimeoutSec -w '%{http_code}' $Url 2>$null
    # 000 表示连接层面失败;2xx/3xx/401/403 都说明站点是通的
    return ($code -match '^\d{3}$') -and ($code -ne '000')
}

function Invoke-Download {
    <#
        用 curl 下载单个文件。刻意不用 Invoke-WebRequest:
        后者在 PowerShell 5.1 上会把整个响应读进内存,下载 GB 级文件时会爆内存。
        curl 是流式写盘。
    #>
    param(
        [string] $Url,
        [string] $Destination,
        [string] $Label
    )

    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # 同 Test-Reachable:curl 的进度条走 stderr,在 'Stop' 策略下会被误判为错误。
    # 这里靠 $LASTEXITCODE 判断成败,不依赖 PowerShell 的错误流。
    $ErrorActionPreference = 'Continue'

    # -L 跟随重定向(HF 会重定向到 CDN);-f 让 HTTP 错误码变成非零退出码,
    # 否则 curl 会把 404 页面当正常内容写进文件。
    & curl.exe -L -f --progress-bar -o $Destination $Url
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path $Destination) { Remove-Item $Destination -Force }
        throw "下载失败($Label):$Url"
    }
    if (-not (Test-Path $Destination)) {
        throw "下载后文件不存在($Label):$Destination"
    }
    if ((Get-Item $Destination).Length -eq 0) {
        Remove-Item $Destination -Force
        throw "下载得到空文件($Label):$Url"
    }
}

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------

Write-Step '检查前置工具'
Write-Detail ('curl : ' + (Assert-Command 'curl.exe' '用于下载'))
Write-Detail ('tar  : ' + (Assert-Command 'tar' '用于解压 zip'))
Write-Ok '前置工具就绪'

# ---------------------------------------------------------------------------
# 第一部分:OpenVINO Runtime + Tokenizers 扩展
# ---------------------------------------------------------------------------

if ($What -in @('All', 'Runtime')) {
    Write-Step "获取 OpenVINO GenAI archive $OpenVinoVersion(Runtime + Tokenizers)"

    $tokenizerDll = Join-Path $RuntimeDir 'openvino_tokenizers.dll'

    if ((Test-Path $tokenizerDll) -and -not $Force) {
        Write-Skip 'openvino_tokenizers.dll 已存在,加 -Force 可强制重新获取'
    } else {
        if (-not (Test-Path $TempDir)) {
            New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
        }

        $zipPath = Join-Path $TempDir $GenAiPackage

        if ((Test-Path $zipPath) -and -not $Force) {
            Write-Skip "压缩包已存在,复用:$zipPath"
        } else {
            Write-Detail "下载 $GenAiUrl"
            Write-Detail '(约 200 MB 上下,取决于网络需要几分钟)'
            Invoke-Download -Url $GenAiUrl -Destination $zipPath -Label 'OpenVINO GenAI archive'
            Write-Ok ('下载完成:' + [math]::Round((Get-Item $zipPath).Length / 1MB, 1) + ' MB')
        }

        $extractDir = Join-Path $TempDir 'extracted'
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

        Write-Detail '解压...'
        Push-Location $extractDir
        try {
            & tar -xf $zipPath
            if ($LASTEXITCODE -ne 0) { throw "解压失败:$zipPath" }
        } finally {
            Pop-Location
        }
        Write-Ok '解压完成'

        # 不硬编码包内目录结构 —— 直接按文件名搜索。
        # 包的内部布局在不同版本间变过,搜索比硬编码路径健壮。
        Write-Detail '搜索 DLL...'
        $allDlls = Get-ChildItem $extractDir -Recurse -Filter '*.dll' -File

        if ($allDlls.Count -eq 0) {
            throw "解压后未找到任何 DLL,包结构可能已变化:$extractDir"
        }

        # 只取 Release 版本。两条过滤都必要:
        #   - 排除 \Debug\ 目录
        #   - 排除文件名带 _debug 后缀的(TBB 把 tbb12_debug.dll 这类
        #     直接放在 Release 目录里,只按目录过滤会漏掉 4 个)
        $wanted = $allDlls | Where-Object {
            $_.FullName -notmatch '\\Debug\\' -and $_.BaseName -notmatch '_debug$'
        }

        $tokenizerSource = $wanted | Where-Object { $_.Name -eq 'openvino_tokenizers.dll' } | Select-Object -First 1
        if (-not $tokenizerSource) {
            Write-Warn '包内未找到 openvino_tokenizers.dll'
            Write-Warn '包结构可能已变化。已解压内容保留在下列目录,请手动确认:'
            Write-Warn "  $extractDir"
            throw '未能取得 Tokenizers 扩展'
        }

        if (-not (Test-Path $RuntimeDir)) {
            New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
        }

        # 记录替换前的状态,便于对比
        $before = @{}
        Get-ChildItem $RuntimeDir -Filter '*.dll' -File -ErrorAction SilentlyContinue |
            ForEach-Object { $before[$_.Name] = $_.Length }

        $copied  = 0
        $updated = @()
        $added   = @()

        foreach ($dll in $wanted) {
            $target = Join-Path $RuntimeDir $dll.Name
            $isNew  = -not $before.ContainsKey($dll.Name)
            $isDiff = (-not $isNew) -and ($before[$dll.Name] -ne $dll.Length)

            Copy-Item $dll.FullName -Destination $target -Force
            $copied++
            if ($isNew)  { $added   += $dll.Name }
            if ($isDiff) { $updated += $dll.Name }
        }

        Write-Ok "已就位 $copied 个 DLL 到 runtime\openvino\"
        if ($added.Count -gt 0) {
            Write-Detail "新增 $($added.Count) 个:"
            $added | Sort-Object | ForEach-Object { Write-Detail "  + $_" }
        }
        if ($updated.Count -gt 0) {
            Write-Detail "体积变化 $($updated.Count) 个(archive 版与原 pip 版不同):"
            $updated | Sort-Object | ForEach-Object { Write-Detail "  ~ $_" }
        }

        if (Test-Path $tokenizerDll) {
            Write-Ok 'openvino_tokenizers.dll 已就位 —— tokenizer IR 现在可以加载'
        } else {
            throw '异常:复制后仍未找到 openvino_tokenizers.dll'
        }

        Write-Detail "临时文件保留在 $TempDir(可手动删除,或运行 nimble clean)"
    }
}

# ---------------------------------------------------------------------------
# 第二部分:LLM 模型
# ---------------------------------------------------------------------------

if ($What -in @('All', 'Model')) {

    Write-Step '模型来源'

    $hfUsable = $false
    if ($TryHuggingFace) {
        Write-Detail '按 -TryHuggingFace 探测 huggingface.co ...'
        $hfUsable = Test-Reachable "$HfBase/api/models/OpenVINO/Qwen2.5-1.5B-Instruct-int4-ov" 15
        if ($hfUsable) {
            Write-Ok 'huggingface.co 可达,开始下载'
        } else {
            Write-Warn 'huggingface.co 仍不可达,放弃下载'
        }
    }

    if (-not $hfUsable) {
        if (-not $TryHuggingFace) {
            Write-Warn '默认不尝试 HuggingFace —— 本机实测该站点不可达(HTTP 000)。'
            Write-Detail '若已配置代理并确认可访问,加 -TryHuggingFace 重跑。'
        }
        Write-Host ''
        Write-Host '    OpenVINO 官方预转换的 IR 模型只发布在 HuggingFace 上,' -ForegroundColor Yellow
        Write-Host '    因此本脚本无法自动获取模型。三条可选路径:' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '    [A] 让本机能访问 huggingface.co(配置代理等),然后重跑本脚本。' -ForegroundColor Gray
        Write-Host '        最省事:官方 IR 直接可用,不需要任何模型转换。' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '    [B] 从 ModelScope 下载原始模型,再用 optimum-intel 自行转换为 IR。' -ForegroundColor Gray
        Write-Host '        ModelScope 实测可达。转换需要 Python 工具链(仅开发期使用,' -ForegroundColor DarkGray
        Write-Host '        不进入 Isvik 运行时,符合规范 §0.5.4)。' -ForegroundColor DarkGray
        Write-Host '        注意 pypi.org 本机不可达,需用镜像:' -ForegroundColor DarkGray
        Write-Host '          -i https://pypi.tuna.tsinghua.edu.cn/simple' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '    [C] 暂不引入 LLM,先用本机已有的 ONNX 模型推进。' -ForegroundColor Gray
        Write-Host '        C:\nim\NimVoice\models\ 下有可用的 ONNX,足以验证' -ForegroundColor DarkGray
        Write-Host '        「读模型 → 编译 → 推理」链路与多属性编译路径。' -ForegroundColor DarkGray
        Write-Host '        但 isvik run 的文本生成与 Tokens/sec 指标需要 LLM。' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '    详见 docs\installation.md。' -ForegroundColor Yellow
        Write-Host ''
        Write-Warn '已跳过模型获取。Runtime 部分(若指定)不受影响。'
    }

    $selected = if (-not $hfUsable) {
        @()
    } else {
        switch ($Model) {
            'both'  { @('small', 'npu') }
            default { @($Model) }
        }
    }

    foreach ($key in $selected) {
        $spec = $ModelCatalog[$key]
        Write-Step "获取模型 [$key] $($spec.Repo)"
        Write-Detail "用途   : $($spec.Purpose)"
        Write-Detail "许可   : $($spec.License)(模型许可独立于 Isvik 的许可)"
        Write-Detail "体积   : 约 $($spec.SizeMB) MB"
        if ($spec.Note) { Write-Warn $spec.Note }

        $targetDir = Join-Path $ModelsDir $spec.Dir

        # 完成标记用「必需文件里的第一个 .bin」——不能硬编码 openvino_model.bin,
        # 因为 Gemma 4 没有这个文件(它叫 openvino_language_model.bin)。
        $markerName = $spec.Required | Where-Object { $_ -like '*.bin' } | Select-Object -First 1
        $marker     = Join-Path $targetDir $markerName

        if ((Test-Path $marker) -and -not $Force) {
            Write-Skip "已存在:$targetDir"
            continue
        }

        # 去重:Optional 里可能与 Required 重复(如 tokenizer.json)
        $files = @($spec.Required) + @($spec.Optional | Where-Object { $_ -notin $spec.Required })
        $index = 0
        foreach ($f in $files) {
            $index++
            $url  = "$HfBase/$($spec.Repo)/resolve/main/$f"
            $dest = Join-Path $targetDir $f

            if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0) -and -not $Force) {
                Write-Detail "[$index/$($files.Count)] 跳过(已有) $f"
                continue
            }

            Write-Detail "[$index/$($files.Count)] $f"
            try {
                Invoke-Download -Url $url -Destination $dest -Label $f
            } catch {
                # 缺可选文件不算失败(不同 tokenizer 实现需要的文件不同),
                # 但必须显式说出来,不静默跳过。缺必需文件则直接失败。
                if ($f -in $spec.Optional -and $f -notin $spec.Required) {
                    Write-Warn "$f 在该仓库中不存在,跳过(该文件是可选的)"
                } else {
                    throw
                }
            }
        }

        # 校验必需文件确实到位
        $missing = @()
        foreach ($f in $spec.Required) {
            $p = Join-Path $targetDir $f
            if (-not (Test-Path $p)) { $missing += $f }
        }
        if ($missing.Count -gt 0) {
            throw "模型 $key 缺少必需文件:$($missing -join ', ')"
        }

        $actual = (Get-ChildItem $targetDir -File | Measure-Object -Property Length -Sum).Sum
        Write-Ok ("模型就位:$targetDir(" + [math]::Round($actual / 1MB, 1) + ' MB)')
    }
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------

Write-Step '当前状态'

$dllCount = 0
$dllSize  = 0
if (Test-Path $RuntimeDir) {
    $dlls     = Get-ChildItem $RuntimeDir -Filter '*.dll' -File
    $dllCount = $dlls.Count
    $dllSize  = ($dlls | Measure-Object -Property Length -Sum).Sum
}
Write-Detail ("runtime\openvino : $dllCount 个 DLL," + [math]::Round($dllSize / 1MB, 1) + ' MB')
Write-Detail ('  openvino_c.dll          : ' + (Test-Path (Join-Path $RuntimeDir 'openvino_c.dll')))
Write-Detail ('  openvino_tokenizers.dll : ' + (Test-Path (Join-Path $RuntimeDir 'openvino_tokenizers.dll')))

if (Test-Path $ModelsDir) {
    Write-Detail 'runtime\models :'
    Get-ChildItem $ModelsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $sz = (Get-ChildItem $_.FullName -File -Recurse | Measure-Object -Property Length -Sum).Sum
        Write-Detail ('  ' + $_.Name + '  ' + [math]::Round($sz / 1MB, 1) + ' MB')
    }
} else {
    Write-Detail 'runtime\models : 尚无模型'
}

Write-Host ''
Write-Host '完成。runtime\ 已在 .gitignore 中,不会进入版本库。' -ForegroundColor Green
Write-Host ''
