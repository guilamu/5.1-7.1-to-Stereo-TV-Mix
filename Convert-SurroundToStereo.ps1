# Convert-SurroundToStereo.ps1 - piste stereo "TV" nivelee a partir d'une piste 5.1 / 7.1.
# Copyright (C) 2026 Guillaume
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Ce programme est un logiciel libre : vous pouvez le redistribuer et/ou le modifier selon les
# termes de la GNU Affero General Public License telle que publiee par la Free Software Foundation,
# soit la version 3, soit (a votre choix) toute version ulterieure. Il est distribue dans l'espoir
# qu'il sera utile, mais SANS AUCUNE GARANTIE. Voir le fichier LICENSE pour les termes complets.

<#
.SYNOPSIS
    Convertit la piste 5.1 / 7.1 d'un film ou d'une série en piste stéréo "TV" nivelée :
    dialogues clairs et musiques / bruitages ramenés au niveau des voix.

.DESCRIPTION
    Chaîne de traitement (ffmpeg, 100 % audio ; la vidéo est copiée sans ré-encodage).
    Elle exploite le fait qu'en 5.1 / 7.1 les dialogues sont dans le canal central :

      1. Pré-gain mesuré     : la loudness d'un downmix simple est mesurée (EBU R128) et
                               ramenée à -23 LUFS pour que les traitements réagissent de la
                               même façon quel que soit le film (mixé fort ou faible).
      2. Voie "dialogues"    : le canal central est nivelé vers le haut ET vers le bas
                               (dynaudnorm en mode RMS) : les chuchotements remontent, les
                               cris redescendent, tout converge vers un niveau constant.
      3. Voie "musique/FX"   : avants + surrounds + LFE sont mixés en stéréo, compressés
                               (acompressor) puis plafonnés vers le bas uniquement
                               (dynaudnorm avec gain max = 1) : les passages forts sont
                               ramenés au niveau des voix, les ambiances calmes ne sont
                               PAS amplifiées (pas de souffle ni de "respiration").
      4. Atténuation dialogue: la voie musique/FX est atténuée (sidechaincompress) quand la
                               voie dialogues est active. Nécessaire parce que les deux voies
                               peuvent être fortes simultanément et s'additionner au remix.
      5. Remix               : centre + musique/FX avec un léger avantage au centre.
      6. Normalisation       : gain final mesuré vers la loudness cible (-16 LUFS par défaut)
                               + limiteur true-peak (-1.5 dBTP) pour éviter tout écrêtage.

    Écart entre les effets forts (90e percentile) et le niveau médian des dialogues,
    mesuré sur deux films aux mixages opposés :

                                   avant        après
        Dune (2021)                +5.8 dB      -1.1 dB
        Tenet (2020)              +12.0 dB      +1.9 dB

    Les dialogues faibles remontent de 2 à 2.5 dB par rapport aux dialogues moyens, et les
    ambiances restent 11 à 14 dB sous les voix (pas de souffle remonté).

    Trois passes ffmpeg par fichier : deux passes d'analyse (audio seul, rapides) puis une passe
    d'encodage / remux. La piste stéréo est placée en premier et titrée « TV Stereo (Night Mode) »,
    mais le flag "default" reste sur la piste d'origine, qui est conservée (sauf -DropOriginalAudio) :
    la lecture démarre donc sur le 5.1 tant que l'utilisateur ne choisit pas la stéréo.
    -StereoDefault inverse ce choix : la stéréo porte alors le flag et la lecture démarre dessus.
    Sous-titres, chapitres et pièces jointes sont copiés.

    Le fichier d'origine est REMPLACÉ : la piste stéréo vient s'ajouter au MKV existant, sans laisser
    de second fichier à côté. Techniquement, ajouter une piste à un MKV impose de réécrire le
    conteneur ; le script écrit donc un fichier temporaire ".part.mkv", contrôle sa durée et son
    nombre de pistes, et ne supprime l'original qu'ensuite. Il faut donc de la place pour les deux
    fichiers pendant la conversion. Pour conserver la source : -Suffix ".stereo" (deux fichiers côte
    à côte) ou -OutputDir (sortie dans un autre dossier).

.PARAMETER Path
    Fichier(s), dossier(s) ou motif(s) générique(s). Un dossier est parcouru récursivement
    (mkv, mp4, m4v, mov, ts, m2ts, avi, wmv, webm). Plusieurs entrées se séparent par des virgules,
    à la façon des cmdlets PowerShell, ou se passent sous forme de tableau :

        .\Convert-SurroundToStereo.ps1 "D:\Films\A.mkv","D:\Films\B.mkv"
        .\Convert-SurroundToStereo.ps1 "D:\Series\Saison 1\*.mkv"
        .\Convert-SurroundToStereo.ps1 (Get-ChildItem "D:\Films" -Filter *.mkv).FullName

    Si omis (script lancé sans argument, ex. double-clic), une invite demande quoi traiter ;
    répondre par Entrée sans rien taper traite tous les fichiers vidéo du dossier courant.

    Pour un usage à la souris, passer par « Convertir-en-stereo.cmd », placé à côté de ce script :
    on peut y déposer des fichiers ou des dossiers (glisser-déposer) ou simplement le double-cliquer,
    et la fenêtre reste ouverte à la fin. Windows ne sait faire ni l'un ni l'autre avec un .ps1
    (le double-clic l'ouvre dans le Bloc-notes, et l'explorateur refuse le dépôt).

.PARAMETER Mode
    night    (défaut) : nivellement fort, type "mode nuit".
    balanced          : nivellement modéré, garde un peu de relief.

.PARAMETER Codec
    aac (défaut), ac3, eac3 ou flac pour la piste stéréo.

.PARAMETER Bitrate
    Débit de la piste stéréo (défaut 192k). Ignoré pour flac.
    L'encodeur AAC natif de ffmpeg travaille en débit moyen : le résultat réel se situe quelques
    pour cent sous la consigne, et descend davantage sur les passages calmes.

.PARAMETER TargetLufs
    Loudness intégrée cible de la piste stéréo (défaut -16).

.PARAMETER TruePeak
    Plafond true-peak en dBTP (défaut -1.5).

.PARAMETER Language
    Langue préférée (code ISO 639-2 : fre, eng, ...) pour choisir la piste source quand il y en a plusieurs.

.PARAMETER AudioStream
    Force l'index (0-based, parmi les pistes audio) de la piste source à convertir.

.PARAMETER OutputDir
    Écrit le résultat dans ce dossier, sous le même nom de fichier, et laisse la source intacte.
    Par défaut (dossier non précisé), le fichier d'origine est remplacé.

.PARAMETER Suffix
    Suffixe ajouté au nom de fichier, ex. ".stereo". Vide par défaut : la sortie porte le nom du
    fichier source et le remplace. Donner un suffixe rétablit l'ancien comportement, à savoir deux
    fichiers côte à côte, l'original étant alors conservé.

.PARAMETER DropOriginalAudio
    Ne garde que la piste stéréo dans le fichier de sortie. Elle devient alors la piste par défaut,
    faute d'autre piste audio.

.PARAMETER StereoDefault
    Pose le flag « default » sur la piste stéréo produite : la lecture démarre alors dessus.
    Sans ce commutateur, le flag reste sur la piste d'origine (5.1 / 7.1) et la stéréo doit être
    choisie manuellement dans le lecteur.

.PARAMETER Ask
    Pose en console les questions dont la réponse n'a pas été donnée sur la ligne de commande
    (aujourd'hui : la piste par défaut) avant de démarrer le lot. Utilisé par
    « Convertir-en-stereo.cmd ». Sans effet si le paramètre correspondant est déjà fourni ou si
    la console n'est pas interactive.

.PARAMETER PreviewFrom
    Produit un extrait (ex. "00:45:00") au lieu du film complet. L'analyse reste faite sur le film entier.

.PARAMETER PreviewLength
    Durée de l'extrait en secondes (défaut 90).

.PARAMETER Verify
    Mesure la loudness de la piste stéréo produite après encodage et l'affiche.

.PARAMETER Overwrite
    Écrase un fichier de sortie existant, et retraite un fichier qui contient déjà une piste
    « TV Stereo » : l'ancienne piste générée est alors remplacée, pas empilée.

.PARAMETER FFmpegPath
    Dossier contenant ffmpeg.exe / ffprobe.exe s'ils ne sont pas dans le PATH.

.EXAMPLE
    .\Convert-SurroundToStereo.ps1 "D:\Films\Dune.mkv"

.EXAMPLE
    .\Convert-SurroundToStereo.ps1 "D:\Séries\Dark" -Language fre -Mode balanced

.EXAMPLE
    .\Convert-SurroundToStereo.ps1 "D:\Films\Dune.mkv" -Suffix ".stereo"
    (garde le fichier d'origine et écrit Dune.stereo.mkv à côté)

.EXAMPLE
    .\Convert-SurroundToStereo.ps1 "D:\Films\Dune.mkv" -StereoDefault
    (la piste stéréo devient celle que le lecteur sélectionne au démarrage)

.EXAMPLE
    .\Convert-SurroundToStereo.ps1 "D:\Films\Dune.mkv" -PreviewFrom 00:45:00 -PreviewLength 120

.EXAMPLE
    .\Convert-SurroundToStereo.ps1
    (sans argument : l'invite demande un fichier/dossier ; Entrée seule = tout le dossier courant)
#>
[CmdletBinding()]
param(
    # Pas de ValueFromRemainingArguments : sous PowerShell 5.1 il aplatit un tableau passé en
    # argument en une seule chaîne jointe par des espaces, ce qui casse tout appel scripté.
    # Pas Mandatory non plus : un $Path vide déclenche l'invite interactive ci-dessous plutôt
    # que la demande de paramètre générique de PowerShell (moins parlante, pas de "tout traiter").
    [Parameter(Position = 0)]
    [string[]]$Path = @(),

    [ValidateSet('night', 'balanced')]
    [string]$Mode = 'night',

    [ValidateSet('aac', 'ac3', 'eac3', 'flac')]
    [string]$Codec = 'aac',

    [string]$Bitrate = '192k',
    [double]$TargetLufs = -16,
    [double]$TruePeak = -1.5,
    [string]$Language = '',
    [int]$AudioStream = -1,
    [string]$OutputDir = '',
    # Vide = la sortie remplace le fichier source (pas de second MKV qui traîne).
    [string]$Suffix = '',
    [switch]$DropOriginalAudio,
    # Non fourni = le flag "default" reste sur la piste d'origine, comportement historique.
    [switch]$StereoDefault,
    [string]$PreviewFrom = '',
    [int]$PreviewLength = 90,
    [switch]$Verify,
    [switch]$Overwrite,
    [switch]$Ask,
    [string]$FFmpegPath = ''
)

$ErrorActionPreference = 'Stop'
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:VideoExt = @('.mkv', '.mp4', '.m4v', '.mov', '.ts', '.m2ts', '.avi', '.wmv', '.webm')

# ---------------------------------------------------------------------------
# Presets
# ---------------------------------------------------------------------------
$script:Presets = @{
    night = @{
        # Voie centre : nivellement RMS montant/descendant (m = gain max linéaire, 5 = +14 dB)
        Center    = 'dynaudnorm=f=400:g=15:p=0.9:m=5:r=0.15:t=0'
        # Voie musique/FX : compression puis plafonnement descendant seul (m=1 = jamais amplifié)
        Rest      = 'acompressor=threshold=-20dB:ratio=4:attack=10:release=250:knee=8:detection=rms:link=average,dynaudnorm=f=400:g=15:p=0.9:m=1:r=0.10:t=0'
        # Atténuation de la voie musique/FX pilotée par la voie dialogues. Mettre '' pour désactiver.
        Duck      = 'sidechaincompress=threshold=0.03:ratio=4:attack=20:release=400:detection=rms:link=average'
        MixCenter = 1.0
        MixRest   = 0.8
    }
    balanced = @{
        Center    = 'dynaudnorm=f=500:g=31:p=0.9:m=3:r=0.15:t=0'
        Rest      = 'acompressor=threshold=-16dB:ratio=2.5:attack=15:release=300:knee=6:detection=rms:link=average,dynaudnorm=f=500:g=31:p=0.9:m=1:r=0.15:t=0'
        Duck      = 'sidechaincompress=threshold=0.05:ratio=3:attack=20:release=400:detection=rms:link=average'
        MixCenter = 1.0
        MixRest   = 0.85
    }
}
# Pondération des canaux dans la voie musique/FX (relatif aux avants = 1.0)
$script:RestSurround = 0.7
$script:RestLfe      = 0.3
$script:PreGainRefLufs = -23.0   # niveau de référence avant traitement

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Fmt([double]$v, [string]$f = '0.##') { return $v.ToString($f, $script:Inv) }

function ParseNum([string]$s) { return [double]::Parse($s, $script:Inv) }

function Quote-Arg([string]$s) {
    # Quoting compatible CommandLineToArgvW
    if ($s -eq '') { return '""' }
    if ($s -notmatch '[\s"]') { return $s }
    $s = $s -replace '(\\*)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return '"' + $s + '"'
}

function Find-Tool([string]$name) {
    if ($FFmpegPath) {
        $p = Join-Path $FFmpegPath "$name.exe"
        if (Test-Path -LiteralPath $p) { return $p }
        throw "$name.exe introuvable dans $FFmpegPath"
    }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "$name introuvable dans le PATH (utilise -FFmpegPath)." }
    return $cmd.Source
}

function Write-Step([string]$msg) { Write-Host ("  " + $msg) -ForegroundColor Cyan }
function Write-Info([string]$msg) { Write-Host ("    " + $msg) -ForegroundColor Gray }
function Write-Ok([string]$msg)   { Write-Host ("  " + $msg) -ForegroundColor Green }
function Write-Warn2([string]$msg){ Write-Host ("  " + $msg) -ForegroundColor Yellow }

function Read-YesNo([string]$question, [bool]$defaultYes) {
    # Question o/n avec valeur par defaut sur Entree. Renvoie la valeur par defaut sans rien
    # demander si la console n'est pas interactive (tache planifiee, -NonInteractive) : Read-Host
    # y leve une exception, ce qui ferait echouer tout le lot pour une simple option.
    $hint = 'o/N'
    if ($defaultYes) { $hint = 'O/n' }
    if (-not [Environment]::UserInteractive) { return $defaultYes }
    while ($true) {
        try { $r = Read-Host ("{0} [{1}]" -f $question, $hint) } catch { return $defaultYes }
        if ([string]::IsNullOrWhiteSpace($r)) { return $defaultYes }
        $v = $r.Trim().ToLowerInvariant()
        if ($v -eq 'o' -or $v -eq 'oui' -or $v -eq 'y' -or $v -eq 'yes') { return $true }
        if ($v -eq 'n' -or $v -eq 'non' -or $v -eq 'no') { return $false }
        Write-Host "  Reponse non comprise : taper o, n, ou Entree pour la valeur par defaut." -ForegroundColor Yellow
    }
}

function Invoke-FFmpeg {
    param(
        [string[]]$Arguments,
        [double]$DurationSec,
        [string]$Activity
    )
    $tmp  = [IO.Path]::GetTempPath()
    $id   = [guid]::NewGuid().ToString('N')
    $prog = Join-Path $tmp "ffs_$id.progress"
    $err  = Join-Path $tmp "ffs_$id.err"
    $out  = Join-Path $tmp "ffs_$id.out"

    $full = @('-hide_banner', '-nostdin', '-nostats', '-y', '-progress', $prog) + $Arguments
    $argLine = ($full | ForEach-Object { Quote-Arg $_ }) -join ' '
    Write-Verbose "ffmpeg $argLine"

    $p = Start-Process -FilePath $script:FFmpeg -ArgumentList $argLine -NoNewWindow -PassThru `
        -RedirectStandardError $err -RedirectStandardOutput $out
    $null = $p.Handle
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastPct = -1
    try {
        while (-not $p.HasExited) {
            Start-Sleep -Milliseconds 500
            if ($DurationSec -gt 0 -and (Test-Path -LiteralPath $prog)) {
                $txt = ''
                try {
                    $fs = [IO.File]::Open($prog, 'Open', 'Read', 'ReadWrite')
                    $fs.Seek([Math]::Max(0, $fs.Length - 4096), 'Begin') | Out-Null
                    $sr = New-Object IO.StreamReader($fs)
                    $txt = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
                } catch {}
                $m = [regex]::Matches($txt, 'out_time_us=(\d+)')
                if ($m.Count -gt 0) {
                    $sec = [double]$m[$m.Count - 1].Groups[1].Value / 1e6
                    $pct = [Math]::Min(100, [int](100 * $sec / $DurationSec))
                    if ($pct -ne $lastPct) {
                        $el = $sw.Elapsed.TotalSeconds
                        $eta = 0
                        if ($sec -gt 0) { $eta = [int](($DurationSec - $sec) * $el / $sec) }
                        $speed = '?'
                        if ($el -gt 0) { $speed = Fmt ($sec / $el) '0' }
                        Write-Progress -Activity $Activity -Status ("{0}%  vitesse {1}x  reste ~{2}" -f $pct, $speed, [TimeSpan]::FromSeconds($eta).ToString('hh\:mm\:ss')) -PercentComplete $pct
                        $lastPct = $pct
                    }
                }
            }
        }
        $p.WaitForExit()
    } finally {
        Write-Progress -Activity $Activity -Completed
    }
    $stderr = ''
    if (Test-Path -LiteralPath $err) { $stderr = [IO.File]::ReadAllText($err) }
    foreach ($f in @($prog, $err, $out)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ ExitCode = $p.ExitCode; StdErr = $stderr; Seconds = $sw.Elapsed.TotalSeconds }
}

function Assert-FFmpegOk($result, [string]$what) {
    if ($result.ExitCode -ne 0) {
        $lines = @($result.StdErr -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -Last 25)
        $tail = $lines -join "`n"
        throw "ffmpeg a échoué ($what), code $($result.ExitCode) :`n$tail"
    }
}

function Parse-Ebur128([string]$stderr) {
    $i   = [regex]::Match($stderr, 'I:\s+(-?[\d.]+|-inf)\s+LUFS')
    $lra = [regex]::Match($stderr, 'LRA:\s+(-?[\d.]+)\s+LU')
    $tp  = [regex]::Match($stderr, 'Peak:\s+(-?[\d.]+|-inf)\s+dBFS')
    if (-not $i.Success -or $i.Groups[1].Value -eq '-inf') {
        throw "Impossible de mesurer la loudness (piste silencieuse ou erreur ffmpeg)."
    }
    $tpv = -99.0
    if ($tp.Success -and $tp.Groups[1].Value -ne '-inf') { $tpv = ParseNum $tp.Groups[1].Value }
    $lrav = 0.0
    if ($lra.Success) { $lrav = ParseNum $lra.Groups[1].Value }
    return [pscustomobject]@{ I = (ParseNum $i.Groups[1].Value); LRA = $lrav; TP = $tpv }
}

function Get-MediaInfo([string]$file) {
    $pargs = @('-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', $file)
    $json = & $script:FFprobe @pargs 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { throw "ffprobe n'a pas pu lire le fichier." }
    return ($json -join "`n") | ConvertFrom-Json
}

function Get-GeneratedAudio($info) {
    # Index (0-based, parmi les pistes audio) des pistes stéréo déjà produites par ce script,
    # reconnues à leur titre. Sert à ne pas empiler une seconde piste sur un fichier déjà traité :
    # depuis que la sortie remplace la source, le nom du fichier ne dit plus s'il a été converti.
    $audios = @($info.streams | Where-Object { $_.codec_type -eq 'audio' })
    $found = @()
    for ($k = 0; $k -lt $audios.Count; $k++) {
        $t = ''
        if ($audios[$k].tags -and $audios[$k].tags.title) { $t = [string]$audios[$k].tags.title }
        if ([int]$audios[$k].channels -le 2 -and ($t -like 'TV Stereo*' -or $t -like 'Stéréo TV*')) {
            $found += $k
        }
    }
    return $found
}

function Test-OutputSane([string]$produced, [string]$source, [double]$srcDuration, [int]$expectedAudio, [bool]$checkSize) {
    # Contrôles avant de supprimer l'original. Renvoie '' si tout va bien, sinon la raison.
    # Pas de seuil de taille absolu : la vidéo étant recopiée telle quelle, la sortie doit peser
    # à peu près comme la source, quel que soit le film. Comparaison désactivée sous
    # -DropOriginalAudio, où la sortie perd légitimement une piste qui peut être volumineuse.
    if (-not (Test-Path -LiteralPath $produced)) { return 'fichier absent' }
    $sizeOut = (Get-Item -LiteralPath $produced).Length
    $sizeIn  = (Get-Item -LiteralPath $source).Length
    if ($checkSize -and $sizeOut -lt $sizeIn * 0.5) { return 'fichier anormalement petit face à la source' }
    try { $pi = Get-MediaInfo $produced } catch { return 'illisible par ffprobe' }
    $d = 0.0
    if ($pi.format -and $pi.format.duration) { $d = ParseNum $pi.format.duration }
    $tol = [Math]::Max(1.0, $srcDuration * 0.01)
    if ($srcDuration -gt 0 -and [Math]::Abs($d - $srcDuration) -gt $tol) {
        return ("durée {0} s au lieu de {1} s" -f (Fmt $d '0'), (Fmt $srcDuration '0'))
    }
    $na = @($pi.streams | Where-Object { $_.codec_type -eq 'audio' }).Count
    if ($na -ne $expectedAudio) { return "$na piste(s) audio au lieu de $expectedAudio" }
    return ''
}

function Select-SourceAudio($info) {
    $audios = @($info.streams | Where-Object { $_.codec_type -eq 'audio' })
    if ($audios.Count -eq 0) { return $null }
    if ($AudioStream -ge 0) {
        if ($AudioStream -ge $audios.Count) { throw "Piste audio $AudioStream inexistante ($($audios.Count) piste(s))." }
        return @{ Stream = $audios[$AudioStream]; Index = $AudioStream; Count = $audios.Count }
    }
    $best = $null; $bestScore = -1; $bestIdx = -1
    for ($k = 0; $k -lt $audios.Count; $k++) {
        $a = $audios[$k]
        if ([int]$a.channels -lt 3) { continue }
        $score = [int]$a.channels
        $lang = ''
        if ($a.tags -and $a.tags.language) { $lang = [string]$a.tags.language }
        if ($Language -and $lang -eq $Language) { $score += 1000 }
        if ($a.disposition -and [int]$a.disposition.default -eq 1) { $score += 100 }
        if ($score -gt $bestScore) { $bestScore = $score; $best = $a; $bestIdx = $k }
    }
    if ($null -eq $best) { return $null }
    return @{ Stream = $best; Index = $bestIdx; Count = $audios.Count }
}

function Get-RestPan([string]$layout) {
    $side = $script:RestSurround
    $back = $script:RestSurround
    # Une vraie 7.1 a des surrounds latéraux ET arrière : on baisse un peu les arrières
    # pour ne pas doubler l'énergie surround par rapport à une 5.1.
    if ($layout -like '7.1*') { $back = [Math]::Round($script:RestSurround * 0.7, 3) }
    $lfe = Fmt $script:RestLfe '0.###'
    $fl = "FL=FL+{0}*SL+{1}*BL+{2}*LFE" -f (Fmt $side '0.###'), (Fmt $back '0.###'), $lfe
    $fr = "FR=FR+{0}*SR+{1}*BR+{2}*LFE" -f (Fmt $side '0.###'), (Fmt $back '0.###'), $lfe
    return "pan=stereo|$fl|$fr"
}

function Get-FilterChain {
    <#
      Stage 'downmix' : downmix simple (centre + reste) -> ebur128        (passe 1)
      Stage 'analyze' : graphe complet sans gain final -> ebur128         (passe 2)
      Stage 'final'   : graphe complet + gain final + limiteur -> [out]   (passe 3)
      aformat=7.1 : toute disposition (5.1, 5.1(side), 6.1, 7.1...) est projetée sur 8 canaux
      nommés (les canaux absents sont silencieux), d'où des formules pan uniques.
    #>
    param([string]$InLabel, [string]$Layout, $Preset, [string]$Stage, [double]$PreGain, [double]$FinalGain)
    $mc = Fmt $Preset.MixCenter '0.###'
    $mr = Fmt $Preset.MixRest '0.###'
    $restPan = Get-RestPan $Layout
    $meter = 'ebur128=peak=true:framelog=quiet'

    if ($Stage -eq 'downmix') {
        # Même pondération que le remix final, sans traitement dynamique.
        $side = $script:RestSurround; $back = $side
        if ($Layout -like '7.1*') { $back = [Math]::Round($side * 0.7, 3) }
        $r = [double]$Preset.MixRest
        $pan = "pan=stereo|FL={0}*FC+{1}*FL+{2}*SL+{3}*BL+{4}*LFE|FR={0}*FC+{1}*FR+{2}*SR+{3}*BR+{4}*LFE" -f `
            $mc, (Fmt $r '0.###'), (Fmt ($r * $side) '0.###'), (Fmt ($r * $back) '0.###'), (Fmt ($r * $script:RestLfe) '0.###')
        return "[$InLabel]aformat=sample_fmts=fltp:channel_layouts=7.1,$pan,highpass=f=40:poles=2,$meter[out]"
    }

    $tail = $meter
    if ($Stage -eq 'final') {
        # Les codecs avec perte (AAC, AC-3...) ajoutent ~1 à 2 dB de dépassement inter-échantillons :
        # le limiteur vise 2 dB sous la cible pour que le fichier final respecte bien -TruePeak.
        $limitDb = $TruePeak
        if ($Codec -ne 'flac') { $limitDb = $TruePeak - 2 }
        $limit = [Math]::Pow(10, $limitDb / 20)
        $tail = ("volume={0}dB,alimiter=limit={1}:attack=5:release=50:level=0:latency=1" -f (Fmt $FinalGain '0.00'), (Fmt $limit '0.####'))
    }
    $g = @()
    $g += ("[{0}]aformat=sample_fmts=fltp:channel_layouts=7.1,volume={1}dB,asplit=2[c][r]" -f $InLabel, (Fmt $PreGain '0.00'))
    if ($Preset.Duck) {
        # La voie centre traitée sert de clé : la musique/FX baisse quand des dialogues sont présents.
        $g += ("[c]pan=mono|c0=FC,{0},asplit=2[cc][sc]" -f $Preset.Center)
        $g += ("[r]{0},highpass=f=40:poles=2,{1}[rr0]" -f $restPan, $Preset.Rest)
        $g += ("[rr0][sc]{0}[rr]" -f $Preset.Duck)
    } else {
        $g += ("[c]pan=mono|c0=FC,{0}[cc]" -f $Preset.Center)
        $g += ("[r]{0},highpass=f=40:poles=2,{1}[rr]" -f $restPan, $Preset.Rest)
    }
    # amerge mono(FC) + stereo(FL,FR) -> disposition 3.0, canaux adressés par nom.
    $g += ("[cc][rr]amerge=inputs=2,pan=stereo|FL={0}*FC+{1}*FL|FR={0}*FC+{1}*FR,{2}[out]" -f $mc, $mr, $tail)
    return ($g -join ';')
}

# ---------------------------------------------------------------------------
# Traitement d'un fichier
# ---------------------------------------------------------------------------
function Convert-File([string]$file) {
    $swFile = [Diagnostics.Stopwatch]::StartNew()
    $name = [IO.Path]::GetFileName($file)
    $base = [IO.Path]::GetFileNameWithoutExtension($file)
    Write-Host ""
    Write-Host "=== $name" -ForegroundColor White

    # $Suffix vide : EndsWith('') est vrai pour n'importe quel nom, d'où le test explicite.
    if ($base.EndsWith('.preview', [StringComparison]::OrdinalIgnoreCase) -or
        ($Suffix -and $base.EndsWith($Suffix, [StringComparison]::OrdinalIgnoreCase))) {
        Write-Warn2 "Ignoré : déjà un fichier de sortie."
        return
    }

    $dir = [IO.Path]::GetDirectoryName($file)
    if ($OutputDir) { $dir = $OutputDir }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $outSuffix = $Suffix
    if ($PreviewFrom) { $outSuffix = '.preview' }
    $outFile = Join-Path $dir ($base + $outSuffix + '.mkv')
    $partFile = Join-Path $dir ($base + $outSuffix + '.part.mkv')
    # Sans -Suffix, -OutputDir ni -PreviewFrom, la sortie prend la place de la source : la piste
    # stéréo s'ajoute au film et il ne reste qu'un fichier.
    $inPlace = (-not $PreviewFrom) -and (-not $Suffix) -and (-not $OutputDir)
    $sameName = [IO.Path]::GetFullPath($outFile) -eq [IO.Path]::GetFullPath($file)
    if ((Test-Path -LiteralPath $outFile) -and -not $sameName -and -not $Overwrite) {
        Write-Warn2 "Ignoré : $([IO.Path]::GetFileName($outFile)) existe déjà (-Overwrite pour écraser)."
        return
    }

    $info = Get-MediaInfo $file
    $duration = 0.0
    if ($info.format -and $info.format.duration) { $duration = ParseNum $info.format.duration }
    $gen = @(Get-GeneratedAudio $info)
    if ($gen.Count -gt 0 -and -not $Overwrite) {
        Write-Warn2 "Ignoré : contient déjà une piste stéréo produite par ce script (-Overwrite pour la refaire)."
        return
    }
    $sel = Select-SourceAudio $info
    if ($null -eq $sel) {
        Write-Warn2 "Ignoré : aucune piste audio à 3 canaux ou plus."
        return
    }
    $src = $sel.Stream
    $srcIdx = $sel.Index
    $layout = "$($src.channels) canaux"
    if ($src.channel_layout) { $layout = [string]$src.channel_layout }
    $lang = 'und'
    if ($src.tags -and $src.tags.language) { $lang = [string]$src.tags.language }
    $srcTitle = ''
    if ($src.tags -and $src.tags.title) { $srcTitle = [string]$src.tags.title }
    Write-Info ("Piste source : a:{0}  {1}  {2}  {3} {4}" -f $srcIdx, $src.codec_name, $layout, $lang, $srcTitle)
    Write-Info ("Durée : {0}   Mode : {1}   Cible : {2} LUFS / {3} dBTP" -f [TimeSpan]::FromSeconds($duration).ToString('hh\:mm\:ss'), $Mode, (Fmt $TargetLufs), (Fmt $TruePeak))
    if ($inPlace) { Write-Info "Sortie : le fichier d'origine sera remplacé (piste ajoutée, pas de second fichier)." }
    else          { Write-Info ("Sortie : {0} (fichier d'origine conservé)" -f [IO.Path]::GetFileName($outFile)) }
    if ($DropOriginalAudio) { Write-Info "Piste par défaut : la stéréo (seule piste audio conservée)." }
    elseif ($StereoDefault) { Write-Info "Piste par défaut : la stéréo." }
    else                    { Write-Info ("Piste par défaut : la piste d'origine ({0}) - -StereoDefault pour la stéréo." -f $layout) }

    $preset = $script:Presets[$Mode]
    $inLabel = "0:a:$srcIdx"

    # --- Passe 1 : loudness du downmix brut -----------------------------------
    Write-Step "Passe 1/3 : analyse du downmix..."
    $fc = Get-FilterChain -InLabel $inLabel -Layout $layout -Preset $preset -Stage 'downmix'
    $r = Invoke-FFmpeg -Arguments @('-i', $file, '-filter_complex', $fc, '-map', '[out]', '-f', 'null', '-') -DurationSec $duration -Activity "Passe 1/3 - $name"
    Assert-FFmpegOk $r 'passe 1'
    $m1 = Parse-Ebur128 $r.StdErr
    $preGain = $script:PreGainRefLufs - $m1.I
    Write-Info ("Downmix : I = {0} LUFS   LRA = {1} LU   TP = {2} dBTP   -> pré-gain {3} dB  ({4} s)" -f (Fmt $m1.I '0.0'), (Fmt $m1.LRA '0.0'), (Fmt $m1.TP '0.0'), (Fmt $preGain '0.0'), (Fmt $r.Seconds '0'))

    # --- Passe 2 : loudness après compression / nivellement -------------------
    Write-Step "Passe 2/3 : analyse après nivellement..."
    $fc = Get-FilterChain -InLabel $inLabel -Layout $layout -Preset $preset -Stage 'analyze' -PreGain $preGain
    $r = Invoke-FFmpeg -Arguments @('-i', $file, '-filter_complex', $fc, '-map', '[out]', '-f', 'null', '-') -DurationSec $duration -Activity "Passe 2/3 - $name"
    Assert-FFmpegOk $r 'passe 2'
    $m2 = Parse-Ebur128 $r.StdErr
    $finalGain = $TargetLufs - $m2.I
    Write-Info ("Nivelé  : I = {0} LUFS   LRA = {1} LU   TP = {2} dBTP   -> gain final {3} dB  ({4} s)" -f (Fmt $m2.I '0.0'), (Fmt $m2.LRA '0.0'), (Fmt $m2.TP '0.0'), (Fmt $finalGain '0.0'), (Fmt $r.Seconds '0'))
    Write-Info ("Plage de loudness : {0} LU -> {1} LU" -f (Fmt $m1.LRA '0.0'), (Fmt $m2.LRA '0.0'))

    # --- Passe 3 : encodage + remux -------------------------------------------
    Write-Step "Passe 3/3 : encodage $Codec + remux (vidéo copiée)..."
    $fc = Get-FilterChain -InLabel $inLabel -Layout $layout -Preset $preset -Stage 'final' -PreGain $preGain -FinalGain $finalGain

    $fargs = @()
    $encDuration = $duration
    if ($PreviewFrom) {
        $fargs += @('-ss', $PreviewFrom, '-t', "$PreviewLength")
        $encDuration = $PreviewLength
    }
    $fargs += @('-i', $file, '-filter_complex', $fc)
    $fargs += @('-map', '0:v?', '-map', '[out]')
    # Pistes audio d'origine à recopier. On les mappe une par une pour pouvoir écarter une piste
    # stéréo produite lors d'une exécution précédente (cas -Overwrite) : sinon elle s'empilerait.
    $keep = @()
    if (-not $DropOriginalAudio) {
        $nbAudio = @($info.streams | Where-Object { $_.codec_type -eq 'audio' }).Count
        for ($k = 0; $k -lt $nbAudio; $k++) {
            if ($gen -contains $k) { continue }
            $keep += $k
            $fargs += @('-map', "0:a:$k")
        }
    }
    $fargs += @('-map', '0:s?', '-map', '0:t?', '-map_metadata', '0', '-map_chapters', '0')
    $fargs += @('-c', 'copy')
    $hasMovText = @($info.streams | Where-Object { $_.codec_type -eq 'subtitle' -and $_.codec_name -eq 'mov_text' }).Count -gt 0
    if ($hasMovText) { $fargs += @('-c:s', 'srt') }

    switch ($Codec) {
        'aac'  { $fargs += @('-c:a:0', 'aac',  '-b:a:0', $Bitrate) }
        'ac3'  { $fargs += @('-c:a:0', 'ac3',  '-b:a:0', $Bitrate) }
        'eac3' { $fargs += @('-c:a:0', 'eac3', '-b:a:0', $Bitrate) }
        'flac' { $fargs += @('-c:a:0', 'flac', '-compression_level:a:0', '8') }
    }
    $modeLabel = 'Balanced'
    if ($Mode -eq 'night') { $modeLabel = 'Night Mode' }
    $fargs += @('-metadata:s:a:0', "language=$lang", '-metadata:s:a:0', "title=TV Stereo ($modeLabel)")
    if ($keep.Count -eq 0) {
        # Seule piste audio restante : elle doit porter le flag default.
        $fargs += @('-disposition:a:0', 'default')
    } else {
        # La stéréo est en première position, mais le flag default se pose selon -StereoDefault :
        # sans lui il reste sur la piste d'origine (celle qui a servi au downmix), avec lui il passe
        # sur la stéréo et aucune piste d'origine ne le porte plus.
        $stereoDisp = '0'
        if ($StereoDefault) { $stereoDisp = 'default' }
        $fargs += @('-disposition:a:0', $stereoDisp)
        for ($k = 0; $k -lt $keep.Count; $k++) {
            $disp = '0'
            if (-not $StereoDefault -and $keep[$k] -eq $srcIdx) { $disp = 'default' }
            $fargs += @("-disposition:a:$($k + 1)", $disp)
        }
    }
    $fargs += @('-max_muxing_queue_size', '4096', '-f', 'matroska', $partFile)

    $r = Invoke-FFmpeg -Arguments $fargs -DurationSec $encDuration -Activity "Passe 3/3 - $name"
    if ($r.ExitCode -ne 0) { Remove-Item -LiteralPath $partFile -Force -ErrorAction SilentlyContinue }
    Assert-FFmpegOk $r 'passe 3'
    if ($inPlace) {
        # On ne supprime la source qu'après avoir vérifié que le fichier produit est complet :
        # durée conforme et bon nombre de pistes audio. Sinon on garde les deux et on prévient.
        $why = Test-OutputSane $partFile $file $duration ($keep.Count + 1) (-not $DropOriginalAudio)
        if ($why) {
            throw ("fichier produit suspect ({0}) : l'original est conservé, le résultat reste dans {1}." -f $why, [IO.Path]::GetFileName($partFile))
        }
        Remove-Item -LiteralPath $file -Force
    }
    if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force }
    Rename-Item -LiteralPath $partFile -NewName ([IO.Path]::GetFileName($outFile))
    $size = (Get-Item -LiteralPath $outFile).Length / 1GB
    $verb = 'OK'
    if ($inPlace) { $verb = 'OK (fichier remplacé)' }
    Write-Ok ("{0} : {1}  ({2} Go, {3})" -f $verb, $outFile, (Fmt $size '0.00'), $swFile.Elapsed.ToString('hh\:mm\:ss'))

    # --- Vérification optionnelle ---------------------------------------------
    if ($Verify) {
        Write-Step "Vérification de la piste produite..."
        $r = Invoke-FFmpeg -Arguments @('-i', $outFile, '-filter_complex', '[0:a:0]ebur128=peak=true:framelog=quiet[out]', '-map', '[out]', '-f', 'null', '-') -DurationSec $encDuration -Activity "Vérification - $name"
        Assert-FFmpegOk $r 'vérification'
        $m3 = Parse-Ebur128 $r.StdErr
        Write-Info ("Sortie  : I = {0} LUFS   LRA = {1} LU   TP = {2} dBTP" -f (Fmt $m3.I '0.0'), (Fmt $m3.LRA '0.0'), (Fmt $m3.TP '0.0'))
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$script:AskedForPath = $false
if (-not $Path -or $Path.Count -eq 0) {
    # Lancé sans argument (ex. double-clic) : on demande quoi traiter au lieu de laisser
    # PowerShell afficher sa propre invite de paramètre obligatoire, muette sur l'option
    # "tout le dossier courant".
    Write-Host ""
    Write-Host "Aucun fichier indiqué." -ForegroundColor Yellow
    $reponse = Read-Host ("Fichier, dossier ou motif a traiter (Entree seule = tous les fichiers video de {0})" -f (Get-Location).Path)
    if ([string]::IsNullOrWhiteSpace($reponse)) {
        $Path = @((Get-Location).Path)
    } else {
        # Accepte plusieurs chemins séparés par des virgules, avec ou sans guillemets
        # (utile en cas de copier-coller depuis l'explorateur de fichiers).
        $Path = @($reponse -split ',' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -ne '' })
    }
    if ($Path.Count -eq 0) { Write-Warning "Aucun chemin valide saisi."; exit 1 }
    $script:AskedForPath = $true
}

# Lancement à la souris (double-clic, ou dépôt sur Convertir-en-stereo.cmd qui passe -Ask) : la
# question de la piste par défaut est posée une fois pour tout le lot. Un -StereoDefault explicite
# fait foi et rien n'est demandé, de sorte qu'un appel scripté n'attend jamais de saisie.
if (($Ask -or $script:AskedForPath) -and -not $PSBoundParameters.ContainsKey('StereoDefault') -and -not $DropOriginalAudio) {
    Write-Host ""
    $StereoDefault = Read-YesNo "La piste stereo doit-elle devenir la piste lue par defaut ?" $false
}

$script:FFmpeg  = Find-Tool 'ffmpeg'
$script:FFprobe = Find-Tool 'ffprobe'

$files = New-Object System.Collections.Generic.List[string]
foreach ($p in $Path) {
    # Chemin littéral d'abord (gère crochets et autres caractères jokers dans les noms),
    # motif générique ensuite (ex. "D:\Series\Saison1\*.mkv").
    $items = @()
    if (Test-Path -LiteralPath $p) {
        $items = @(Get-Item -LiteralPath $p)
    } elseif ($p -match '[*?]') {
        $items = @(Get-Item -Path $p -ErrorAction SilentlyContinue)
    }
    if ($items.Count -eq 0) { Write-Warning "Introuvable : $p"; continue }
    foreach ($item in $items) {
        if ($item.PSIsContainer) {
            Get-ChildItem -LiteralPath $item.FullName -Recurse -File |
                Where-Object { $script:VideoExt -contains $_.Extension.ToLowerInvariant() } |
                Sort-Object FullName | ForEach-Object { $files.Add($_.FullName) }
        } elseif ($script:VideoExt -contains $item.Extension.ToLowerInvariant()) {
            $files.Add($item.FullName)
        }
    }
}
$files = [System.Collections.Generic.List[string]]@($files | Select-Object -Unique)
if ($files.Count -eq 0) { Write-Warning "Aucun fichier vidéo à traiter."; exit 1 }

Write-Host ("{0} fichier(s) à traiter - mode {1}, codec {2}, cible {3} LUFS" -f $files.Count, $Mode, $Codec, (Fmt $TargetLufs))
$ok = 0; $failed = 0
foreach ($f in $files) {
    try {
        Convert-File $f
        $ok++
    } catch {
        $failed++
        Write-Host ("  ERREUR : " + $_.Exception.Message) -ForegroundColor Red
    }
}
Write-Host ""
Write-Host ("Terminé : {0} réussi(s), {1} en erreur." -f $ok, $failed) -ForegroundColor White
if ($failed -gt 0) { exit 1 }
