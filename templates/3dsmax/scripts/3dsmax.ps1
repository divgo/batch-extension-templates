param (
    [int]$start = 1,
    [int]$end = 1,
    [string]$outputName = "images\image.jpg",
    [string]$sceneFile,
    [int]$nodeCount = 1,
    [switch]$dr,
    [string]$renderer = "vray",
    [string]$irradianceMap = $null,
    [string]$pathFile = $null,
    [string]$workingDirectory = "$env:AZ_BATCH_JOB_PREP_WORKING_DIR\assets",
    [string]$preRenderScript = $null,
    [string]$camera = $null,
    [string]$additionalArgs = $null,
    [int]$vrayPort = 20204,
    [string]$renderPresetFile = $null,
    [string]$maxVersion = $null,
    [string]$colorCorrectionFile = $null
)
gci env:* | Format-Table -Wrap -AutoSize

Write-Host gci env:* | Format-Table -Wrap -AutoSize

$OutputEncoding = New-Object -typename System.Text.UnicodeEncoding

function ParameterValueSet([string]$value)
{
    return ($value -and -Not ($value -eq "none") -and -Not ([string]::IsNullOrWhiteSpace($value)))
}

function WriteDistributedRenderingConfigs
{
    Write-Host "Setting up DR..."

    $port = $vrayPort
    $vraydr_content = ""
    $vrayrtdr_content = ""
    $hosts = $env:AZ_BATCH_HOST_LIST.Split(",")

    if ($hosts.Count -ne $nodeCount) {
        Write-Host "Host count $hosts.Count must equal nodeCount $nodeCount"
        exit 1
    }

    $env:AZ_BATCH_HOST_LIST.Split(",") | ForEach {
        $vraydr_content += "$_ 1 $port`r`n"
        $vrayrtdr_content += "$_ 1 $port`r`n"
    }

    $vraydr_content += "restart_slaves 0`r`n"
    $vraydr_content += "list_in_scene 0`r`n"
    $vraydr_content += "max_servers 0`r`n"
    $vraydr_content += "use_local_machine 0`r`n"
    $vraydr_content += "transfer_missing_assets 1`r`n"
    $vraydr_content += "use_cached_assets 1`r`n"
    $vraydr_content += "cache_limit_type 2`r`n"
    $vraydr_content += "cache_limit 100.000000"

    $vrayrtdr_content += "autostart_local_slave 0`r`n"

    # Max 2021
    $pluginConfig2021 = "$env:LOCALAPPDATA\Autodesk\3dsMaxIO\2021 - 64bit\ENU\en-US\plugcfg"
    New-Item "$pluginConfig2021" -ItemType Directory -Force
    $vraydr_content | Out-File "$pluginConfig2021\vray_dr.cfg" -Force -Encoding ASCII
    $vrayrtdr_content | Out-File "$pluginConfig2021\vrayrt_dr.cfg" -Force -Encoding ASCII

    # We need to wait for vrayspawner or vray.exe to start before continuing
    Start-Sleep 30
}

# Create pre-render script
$pre_render_script = "prerender.ms"
$pre_render_script_content = "-- Pre render script`r`n"
$pre_render_script_content += "r = renderers.current`r`n"
$pre_render_script_content += "mversion = maxVersion()`r`n"
$pre_render_script_content += "rendererName = r as string`r`n"
#$pre_render_script_content += "r = print ('Using 3ds Max '+ mversion[8] as string)`r`n"

if ($dr)
{
    WriteDistributedRenderingConfigs
    $pre_render_script_content += "r.system_distributedRender = true`r`n"  
}

Write-Host "Using renderer 3ds-Max $maxVersion with $renderer"

if ($renderer -eq "arnold")
{
    Write-Host "3ds Max is using the Arnold renderer " 
    $pre_render_script_content += "-- Fail on arnold license error`r`n"
    $pre_render_script_content += "r.abort_on_license_fail = true`r`n"
    $pre_render_script_content += "r.prepass_enabled = false`r`n"
    $pre_render_script_content += "r.verbosity_level = 4`r`n"
    $pre_render_script_content += "renderMessageManager.LogFileON = true`r`n"
    $pre_render_script_content += "renderMessageManager.ShowInfoMessage = true`r`n"
    $pre_render_script_content += "renderMessageManager.ShowProgressMessage = true`r`n"
    $pre_render_script_content += "renderMessageManager.LogDebugMessage = true`r`n"
}

if ($renderer -like "vray*")
{
    Write-Host "3ds Max is using the Vray renderer: $renderer" 
    $outputPath = "$env:AZ_BATCH_TASK_WORKING_DIR\images\" -replace "\\", "\\"
    $vrayLogFile = "$env:AZ_BATCH_TASK_WORKING_DIR\VRayLog.log" -replace "\\", "\\"

    $pre_render_script_content += "r.system_vrayLog_level = 4`r`n"
    $pre_render_script_content += "r.system_vrayLog_file = ""$vrayLogFile""`r`n"
    $pre_render_script_content += "indexVray5 = findString rendererName ""V_Ray_5_""`r`n"
    $pre_render_script_content += "if (indexVray5 == 1 and r.output_splitgbuffer and r.output_splitfilename != """") then (fileName = ""$outputPath"" + (filenameFromPath r.output_splitfilename); r.output_splitfilename = fileName)`r`n"
    $pre_render_script_content += "if (indexVray5 == 1 and r.output_saveRawFile and r.output_rawFileName != """") then (fileName = ""$outputPath"" + (filenameFromPath r.output_rawFileName); r.output_rawFileName = fileName)`r`n"       

    if (ParameterValueSet $irradianceMap)
    {
        $irMap = "$workingDirectory\$irradianceMap"
        $irMap = $irMap -replace "\\", "\\"
        
        Write-Host "Setting IR map to $irMap"
        $pre_render_script_content += "-- Set the IR path`r`n"
        If ($maxVersion -eq "2021")
        {
            $pre_render_script_content += "r.adv_irradmap_loadFileName = ""$irMap""`r`n"
        }
    }

    if (ParameterValueSet $colorCorrectionFile)
    {
        $ccFile = "$workingDirectory\$colorCorrectionFile"
        $ccFile = $ccFile -replace "\\", "\\"
        
        Write-Host "Setting colorCorrection file to $ccFile"
        $pre_render_script_content += "-- Set the CC filePath`r`n"
        $pre_render_script_content += "vfbControl #loadglobalccpreset ""$ccFile""`r`n"
    }
}

if ((Test-Path ".\RepathRenderElements.ms"))
{
	$remapRenderElementsScript = (Get-Content -Path ".\RepathRenderElements.ms" -Raw)
	$pre_render_script_content += "-- Remap any render element paths`r`n"
	$pre_render_script_content += $remapRenderElementsScript
}

$pre_render_script_content | Out-File $pre_render_script -Encoding ASCII

if (ParameterValueSet $preRenderScript)
{
    $preRenderScript = "$workingDirectory\$preRenderScript"
    
    if (-Not [System.IO.File]::Exists($preRenderScript))
    {        
        Write-Host "Pre-render script $preRenderScript not found, exiting."
        exit 1
    }

    "`r`n" | Out-File -Append $pre_render_script -Encoding ASCII
    Get-Content -Path $preRenderScript | Out-File -Append $pre_render_script -Encoding ASCII
}
else
{
    Write-Host "No pre-render script specified"
}

$sceneFile = "$workingDirectory\$sceneFile"
Write-Host "Using absolute scene file $sceneFile"

$pathFileParam = ""
if (ParameterValueSet $pathFile)
{
    $pathFile = "$workingDirectory\$pathFile"

    if (-Not [System.IO.File]::Exists($pathFile))
    {        
        Write-Host "Path file $pathFile not found, exiting."
        exit 1
    }

    Write-Host "Using path file $pathFile"
    
    # If we're using a path file we need to ensure the scene file is located at the same
    # location otherwise 3ds Max 2018 IO has issues finding textures.
    $sceneFileName = [System.IO.Path]::GetFileName($sceneFile)
    $sceneFileDirectory = [System.IO.Path]::GetDirectoryName("$sceneFile")
    $pathFileDirectory = [System.IO.Path]::GetDirectoryName($pathFile)
    if ($sceneFileDirectory -ne $pathFileDirectory)
    {
        Write-Host "Moving scene file to $pathFileDirectory"
        Move-Item -Force "$sceneFile" "$pathFileDirectory" -ErrorAction Stop > $null
        $sceneFile = "$pathFileDirectory\$sceneFileName"
    }
    $pathFileParam = "-pathFile:`"$pathFile`""
}
else
{
    Write-Host "No path file specified"
}

$cameraParam = ""
if (ParameterValueSet $camera)
{
    Write-Host "Using camera $camera"
    $cameraParam = "-camera:`"$camera`""
}
else
{
    Write-Host "No camera specified"
}

# User specified arguments
$additionalArgumentsParam = ""
if (ParameterValueSet $additionalArgs)
{
    Write-Host "Using additional arguments $additionalArgs"
    $additionalArgumentsParam = $additionalArgs
}

# Default 3ds Max args
$defaultArguments = @{
    '-atmospherics'='0';
    '-renderHidden'='0';
    '-effects'='0';
    '-useAreaLights'='0';
    '-displacements'='0';
    '-force2Sided'='0';
    '-videoColorCheck'='0';
    '-superBlack'='0';
    '-renderFields'='0';
    '-fieldOrder'='Odd';
    '-skipRenderedFrames'='0';
    '-renderElements'='1';
    '-useAdvLight'='0';
    '-computeAdvLight'='0';
    '-ditherPaletted'='0';
    '-ditherTrueColor'='0';
    '-gammaCorrection'='1';
    '-gammaValueIn'='2.2';
    '-gammaValueOut'='2.2';
    '-rfw'='0';
    '-videopostJob'='0';
    '-v'='5';
}

# If the user has specified an argument that overrides a default,
# remove the default.
$additionalArgumentsParam.Split(" ") | % {
    $arg = $_
    if ($arg.StartsWith("-") -And $arg.Contains(":"))
    {
        $name = $arg.Split(":")[0]
        if ($defaultArguments.ContainsKey($name))
        {
            Write-Host "Removing default argument $name as the user has specified $arg"
            $defaultArguments.Remove($name)
        }
    }
}

$defaultArgumentsParam = $defaultArguments.GetEnumerator() | % { "$($_.Name):$($_.Value)" }

$renderPresetFileParam = ""
if (ParameterValueSet $renderPresetFile)
{
    $renderPresetFile = "$workingDirectory\$renderPresetFile"

    if (-Not [System.IO.File]::Exists($renderPresetFile))
    {
        Write-Host "Render preset file $renderPresetFile not found, exiting."
        exit 1
    }

    $renderPresetFileParam = "-preset:`"$renderPresetFile`""
}

# Create folder for outputs
mkdir -Force images > $null

# Render
$max_exec = "3dsmaxcmdio.exe"
If ($maxVersion -eq "2021")
{
        $max_exec = $env:3DSMAX_2021_EXEC
        if(-Not (Test-Path "$env:3DSMAX_2021"))
        {
            Write-Host "3ds Max 2021 doesn't exist on this rendering image, please use a newer version of the rendering image."
            exit 1
        }
}
Else 
{
    Write-Host "No version of 3ds Max was selected. 3ds Max 2021 was selected by default."
    $max_exec = $env:3DSMAX_2021_EXEC
}

Write-Host "Executing $max_exec -secure off $cameraParam $renderPresetFileParam $defaultArgumentsParam $additionalArgumentsParam -preRenderScript:`"$pre_render_script`" -start:$start -end:$end -outputName:`"$outputName`" $pathFileParam `"$sceneFile`""

cmd.exe /c $max_exec -secure off $cameraParam $renderPresetFileParam $defaultArgumentsParam $additionalArgumentsParam -preRenderScript:`"$pre_render_script`" -start:$start -end:$end -v:5 -outputName:`"$outputName`" $pathFileParam `"$sceneFile`" `>Max_frame.log 2`>`&1
$result = $lastexitcode

Write-Host "last exit code $result"

If ($maxVersion -eq "2021")
{  
    Copy-Item "${env:LOCALAPPDATA}\Autodesk\3dsMaxIO\2021 - 64bit\ENU\Network\Max.log" .\Max_full.log -ErrorAction SilentlyContinue 
}

if ($renderer -like "vray*")
{
    Copy-Item "$env:LOCALAPPDATA\Temp\vraylog.txt" . -ErrorAction SilentlyContinue
}

exit $result
