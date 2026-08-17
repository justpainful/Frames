<#
    generate_app_icon.ps1

    Renders the Frames app icon (1024x1024, three appearance variants) into
    Frames/Resources/Assets.xcassets/AppIcon.appiconset.

    The mark is two overlapping frame outlines: one landscape, one portrait.
    It reads as "frames" literally, and says photo + video / horizontal +
    vertical without any literal camera iconography. Monochrome geometry with a
    single system-blue accent, drawn on the icon grid Apple uses (the mark
    occupies the central ~62% of the canvas).

    Requires Windows PowerShell 7+ with System.Drawing.Common.
#>

Add-Type -AssemblyName System.Drawing

$root       = Split-Path -Parent $PSScriptRoot
$outputDir  = Join-Path $root 'Frames\Resources\Assets.xcassets\AppIcon.appiconset'
$size       = 1024

function New-RoundedPath {
    param([double]$X, [double]$Y, [double]$W, [double]$H, [double]$R)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $path.AddArc([float]$X,           [float]$Y,           [float]$d, [float]$d, 180, 90)
    $path.AddArc([float]($X + $W - $d), [float]$Y,           [float]$d, [float]$d, 270, 90)
    $path.AddArc([float]($X + $W - $d), [float]($Y + $H - $d), [float]$d, [float]$d,   0, 90)
    $path.AddArc([float]$X,           [float]($Y + $H - $d), [float]$d, [float]$d,  90, 90)
    $path.CloseFigure()
    return $path
}

function New-FramesIcon {
    param(
        [string]$Path,
        [System.Drawing.Color]$BackgroundTop,
        [System.Drawing.Color]$BackgroundBottom,
        [System.Drawing.Color]$PrimaryStroke,
        [System.Drawing.Color]$AccentStroke,
        [bool]$TransparentBackground = $false
    )

    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    if (-not $TransparentBackground) {
        $rect  = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $rect, $BackgroundTop, $BackgroundBottom, 90.0)
        $g.FillRectangle($brush, $rect)
        $brush.Dispose()
    }

    # Mark geometry. Both frames share a centre and a common stroke weight.
    $stroke   = $size * 0.047
    $centre   = $size / 2.0
    $longSide = $size * 0.600
    $shortSide= $size * 0.372
    $radius   = $size * 0.072

    $landscape = New-RoundedPath -X ($centre - $longSide / 2)  -Y ($centre - $shortSide / 2) `
                                 -W $longSide -H $shortSide -R $radius
    $portrait  = New-RoundedPath -X ($centre - $shortSide / 2) -Y ($centre - $longSide / 2) `
                                 -W $shortSide -H $longSide -R $radius

    $accentPen = New-Object System.Drawing.Pen($AccentStroke, [float]$stroke)
    $accentPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawPath($accentPen, $portrait)
    $accentPen.Dispose()

    $primaryPen = New-Object System.Drawing.Pen($PrimaryStroke, [float]$stroke)
    $primaryPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawPath($primaryPen, $landscape)
    $primaryPen.Dispose()

    $landscape.Dispose(); $portrait.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "wrote $Path"
}

New-FramesIcon -Path (Join-Path $outputDir 'AppIcon.png') `
    -BackgroundTop    ([System.Drawing.Color]::FromArgb(255, 44, 44, 48)) `
    -BackgroundBottom ([System.Drawing.Color]::FromArgb(255, 12, 12, 14)) `
    -PrimaryStroke    ([System.Drawing.Color]::FromArgb(255, 255, 255, 255)) `
    -AccentStroke     ([System.Drawing.Color]::FromArgb(255, 10, 132, 255))

New-FramesIcon -Path (Join-Path $outputDir 'AppIcon-Dark.png') `
    -BackgroundTop    ([System.Drawing.Color]::FromArgb(255, 26, 26, 30)) `
    -BackgroundBottom ([System.Drawing.Color]::FromArgb(255, 0, 0, 0)) `
    -PrimaryStroke    ([System.Drawing.Color]::FromArgb(255, 245, 245, 247)) `
    -AccentStroke     ([System.Drawing.Color]::FromArgb(255, 10, 132, 255))

New-FramesIcon -Path (Join-Path $outputDir 'AppIcon-Tinted.png') `
    -BackgroundTop    ([System.Drawing.Color]::Transparent) `
    -BackgroundBottom ([System.Drawing.Color]::Transparent) `
    -PrimaryStroke    ([System.Drawing.Color]::FromArgb(255, 255, 255, 255)) `
    -AccentStroke     ([System.Drawing.Color]::FromArgb(150, 255, 255, 255)) `
    -TransparentBackground $true
