
<#
.SYNOPSIS
Batch convert video files using ffmpeg.

.DESCRIPTION
This script processes input video files using ffmpeg and ffprobe. Typical use-case is converting, compressing or repacking a large batch of video files using a set of common parameters.

As the script relies on ffmpeg to do the work, it is able to do a subset of what ffmpeg can do. This means it can change media container amd it can re-encode into a different codec (both audio and video), at different levels of quality.

In addition, the script outputs progress information for long encodes. 

The script is a decent PowerShell citizen; it can take files from a pipe and it can output to a downstream pipe. In addition, you can run the script alone, specifying wildcards and individual files to process.

Encoding is always done in 2 passes to optimise quality.

.PARAMETER Quiet
Suppress superfluous output. Default: $false.

.PARAMETER DontMatchDates
Don't set output file dates to match input file dates. Default: $false.

.PARAMETER Extension
The extension, and thus container, for the output files. Default: mp4.

.PARAMETER RequiredImprovement
A percetage value between 0 and 99. Output files that don't show the required level of space saving are discarded. Default: 10.

.PARAMETER VideoEncoder
The video encoder library to be used by ffmpeg. Depending on the build of ffmpeg, some encoders may not be available. Run "ffmpeg -encoders" for the full list.
Common parameters here are libx264, libx265 or libsvtav1. Not all ffmpeg encoders will work here; for example if an encoder doesn't support 2-pass encoding, it cannot be used. Default: libx264.

.PARAMETER VideoQuality
The target kilobits/second for the video encode. The higher the value, the better the quality and the larger the size of the output file. Default: 2000.

.PARAMETER AudioEncoder
The audio encoder library to be used by ffmpeg. Depending on the build of ffmpeg, some encoders may not be available. Run "ffmpeg -encoders" for the full list.
Common parameters here are aac, mp3 or opus. Default: aac.

.PARAMETER AudioQuality
The target kilobits/second for the audio encode. The higher the value, the better the quality and the larger the size of the output file. Default: 128.

.PARAMETER ffMpegLocation
The directory where to find the ffmpeg binary which is required by this script. If not supplied, the script searches in the same directory as the script, then in the system path for a ffmpeg binary. If ffmpeg cannot be located, the script refuses to run.

.PARAMETER ffProbeLocation
The directory where to find the ffprobe binary which is required by this script. If not supplied, the script searches in the same directory as the script, then in the system path for a ffmpeg binary and in the same directory as where it found the ffmpeg executable. If ffprobe cannot be located, the script refuses to run.

.PARAMETER inputFiles
A set of relative of absolute paths to files that you wish the script to process.
You can supply wildcards as well as individual files.

.PARAMETER FullPathOutput
Express output file paths as absolute, full paths. Default: $false.

.EXAMPLE
.\convert.ps1 -ffMpegLocation "C:\Program Files\ffmpeg\" -VideoEncoder "libx265" -VideoQuality 3000 -Extension "mkv" *.mp4
Using the ffmpeg binary found in "C:\Program Files\ffmpeg", all mp4 files in the current folder are compressed into h265 (HEVC) at 3000 kbit/seconds. The output files are stored in a matroska container.

#>




function Clamp {
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [ValidateScript({$maxValue -ge $minValue})]
        $value,
        $minValue,
        $maxValue
    )

    if ($value -lt $minValue) {
        $value = $minValue
    }
    elseif ($value -gt $maxValue) {
        $value = $maxValue
    }

    return $value
}

function Max {
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        $value,
        $maxValue
    )

    if($value -gt $maxValue) {
        return $value
    }

    return $maxValue
}

enum ConversionOutcome {
    Unknown
    Converted
    Discarded
    Unreadable
    Error
}

function DebugPrintArgs {
    param (
        [Parameter(Mandatory=$true, Position=0)]
        [string[]]$Args
    )

    Write-Debug "--> DebugPrintArgs"

    if( $DebugPreference -ne "SilentlyContinue" ) {
        $list_of_args = ""

        foreach ($arg in $Args) {
            $list_of_args += ($arg + " ")
        }

        Write-Debug($list_of_args)
    }

    Write-Debug "<-- DebugPrintArgs"
}


function WriteProgress {
    param (
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Activity,
    
        [Parameter(Mandatory=$true, Position=1)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory=$true, Position=2)]
        [string]$FileNameOriginal,

        [Parameter(Mandatory=$true, Position=3)]
        [string]$FileNameNew,

        [Parameter(Mandatory=$true, Position=4)]
        [string]$LogFileProcess,

        [Parameter(Mandatory=$true, Position=5)]
        [int]$DurationSeconds
    )

    Write-Debug "--> WriteProgress"

    # work-around for a PS bug: https://web.archive.org/web/20230326011220/https://stackoverflow.com/questions/44057728/start-process-system-diagnostics-process-exitcode-is-null-with-nonewwindow
    # basically once the process has finished, many things about the process is no longer available, unless cached while the process is alive
    $handle = $Process.Handle
    $name = $Process.Name
    $start_time = Get-Date

    # wait for pass 1 to finish
    while (!$Process.HasExited) {
        # use SilentlyContinue as the progress log file may not have been written for the first time by the time we come down here.
        $progress_captures = Get-Content $LogFileProcess -ErrorAction SilentlyContinue | Select-String -Pattern "out_time_ms=(\d*)"
        if ($progress_captures) {
            $current_time_s = Max -value ($progress_captures[-1].Matches.Groups[1].Value / 10000) -maxValue 0.00
            $completed_percent = Clamp -value ($current_time_s / $DurationSeconds) -minValue 1 -maxValue 100
            if( !$Quiet ) {
                # figure out how long has passed, so we can calculate how long we have left
                $elapsed_time = (Get-Date) - $start_time
                $time_remaining = ($elapsed_time.TotalSeconds / $completed_percent) * (100 - $completed_percent)
                $activity_message = $Activity + " (" + ('{0:hh\:mm\:ss}' -f ([TimeSpan]::FromSeconds($time_remaining))) + ")"
                Write-Progress -Activity ($FileNameOriginal + " ==> " + $FileNameNew) -PercentComplete $completed_percent -Status $activity_message
            }

            # ffmpeg doesn't write progress more often than 0.5s ... so there's no need to let the script run crazy waiting for an update that never comes
            Start-Sleep -Milliseconds 500
        }
    }

    Write-Debug "<-- WriteProgress"
}

function ProcessFailure {
    param (
        [Parameter(Mandatory=$true, Position=0)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory=$true, Position=1)]
        [string]$ErrorLogFullPath
    )

    Write-Debug "--> ProcessFailure"

    $error_log_length = (Get-Item -Path $ErrorLogFullPath -ErrorAction SilentlyContinue).Length

    # if we've had an error, reprint the error log
    # unfortunately we cannot always rely on the exit code
    # occasionally ffmpeg has a fault but still returns 0 for exit code
    # so we also check the length of the error log. If there's anything in there, we assume there's an error too
    if( ($Process.ExitCode -gt 0) ) {
        $error_log = Get-Content $ErrorLogFullPath -ErrorAction SilentlyContinue
        foreach($line in $error_log) {Write-Warning ($Process.ProcessName + ": " + $line)}
        Write-Debug ("<-- " + $Process.ExitCode)
        return $true
    }

    Write-Debug "<-- ProcessFailure"
    return $false;

}

function GetFileLine {
    param (
        [Parameter(Mandatory=$true, Position=0)]
        [string]$InputFile,
    
        [Parameter(Mandatory=$true, Position=1)]
        [ConversionOutcome]$ConversionOutcome,

        [Parameter(Mandatory=$true, Position=2)]
        [int]$ImprovementPercent,

        [Parameter(Mandatory=$true, Position=3)]
        [string]$OutputFile
    )

    # prepare an output object
    $output_file_line = [PSCustomObject]@{
        Path = $InputFile
        Outcome = $ConversionOutcome
        ImprovementPercent = $ImprovementPercent
        OutputFile = $OutputFile
    }

    return $output_file_line
}

function GetBinaryLocation {
    param (
        [Parameter(Mandatory=$true, Position=0)]
        [AllowEmptyString()]
        [string]$SuggestedLocation,

        [Parameter(Mandatory=$true, Position=1)]
        [string]$BinaryName
    )

    Write-Debug "--> GetBinaryLocation"
    Write-Debug "SuggestionLocation: $SuggestedLocation"
    Write-Debug "BinaryName: $BinaryName"

    # remove last dir seperator, if present
    if( $SuggestedLocation.EndsWith([System.IO.Path]::DirectorySeparatorChar) ) {
        Write-Debug "SuggestedLocation supplied with trailing \ - removing."
        $SuggestedLocation = $SuggestedLocation.Substring(0, $SuggestedLocation.Length - 1)
    }

    # can we find the binary where it was suggested?
    $candidatePath = ($SuggestedLocation + [System.IO.Path]::DirectorySeparatorChar + $BinaryName + ($IsWindows ? ".exe" : "")) 
    if( ![System.IO.Path]::IsPathRooted($candidatePath) )
    {
        Write-Debug "Relative path given. Converting to absolute path."
        try {
            # in case we were given a relative path, convert to absolute
            $candidatePath = Convert-Path -Path $candidatePath -ErrorAction Stop
        } catch {
            Write-Warning "Invalid relative path for $BinaryName"
        }
        Write-Debug "candidatePath is now $candidatePath"
    }

    Write-Debug ("Testing for binary at suggested location " + $candidatePath)
    if (Test-Path -Path $candidatePath -PathType Leaf -ErrorAction SilentlyContinue) {
        Write-Debug "Using binary found at suggested location."
        Write-Debug "<-- $candidatePath"
        return $candidatePath
    }

    # can we find the binary next to the script module?
    $candidatePath = ($PSScriptRoot + [System.IO.Path]::DirectorySeparatorChar + $BinaryName + ($IsWindows ? ".exe" : ""))    
    Write-Debug ("Testing for binary next to script module at " + $candidatePath)
    if (Test-Path -Path $candidatePath -PathType Leaf -ErrorAction SilentlyContinue) {
        Write-Debug "Using binary found next to script."
        Write-Debug "<-- $candidatePath"
        return $candidatePath
    }

    # can we find the binary in the folder where we were called from?
    $calling_dir = Get-Location
    $candidatePath = ($calling_dir.Path + [System.IO.Path]::DirectorySeparatorChar + $BinaryName + ($IsWindows ? ".exe" : ""))    
    Write-Debug ("Testing for binary in calling directory at " + $candidatePath)
    if (Test-Path -Path $candidatePath -PathType Leaf -ErrorAction SilentlyContinue) {
        Write-Debug "Using binary found in calling directory."
        Write-Debug "<-- $candidatePath"
        return $candidatePath
    }

    # can we find the binary in the path?
    $binaryInPath = Get-Command -Name $BinaryName -ErrorAction SilentlyContinue
    if( $binaryInPath ) {
        Write-Debug "Using binary found in the path."
        Write-Debug "<-- $candidatePath"
        return $binaryInPath.Source
    } else {
        Write-Debug "$BinaryName wasn't found in path."
    }
    
    # give up
    Write-Debug "Couldn't determine a location for $BinaryName"
    return ""
}

function Compress-Video {
    [CmdletBinding()]
    param(
       
        [Parameter(Mandatory=$false)]
        [switch]$Quiet = $false,
    
        [Parameter(Mandatory=$false)]
        [switch]$DontMatchDates = $false,
    
        [Parameter(Mandatory=$false)]
        [switch]$FullPathOutput = $false,

        [Parameter(Mandatory=$false)]
        [switch]$Version = $false,
    
        [Parameter(Mandatory=$false)]
        [string]$Extension = "mp4",
    
        [Parameter(Mandatory=$false)]
        [int]$RequiredImprovement = 10,
    
        [Parameter(Mandatory=$false)]
        [string]$VideoEncoder = "libx264",
    
        [Parameter(Mandatory=$false)]
        [int]$VideoQuality = 2000,
        
        [Parameter(Mandatory=$false)]
        [string]$AudioEncoder = "aac",
    
        [Parameter(Mandatory=$false)]
        [int]$AudioQuality = 128,
    
        [Parameter(Mandatory=$false)]
        [string]$ffMpegLocation = "",
    
        [Parameter(Mandatory=$false)]
        [string]$ffProbeLocation = "",
    
        [Parameter(ValueFromPipeline = $true, Position=0, Mandatory=$false, ValueFromRemainingArguments=$true)]
        [string[]]$inputFiles
    )

    begin {
        Write-Debug "begin {}"
        Write-Debug "--> Compress-Video"

        if( $Version ) {
            Write-Host "1.0015"
            return
        }
    
        # find ffmpeg and ffprobe
        $ffmpeg_full_path = GetBinaryLocation $ffMpegLocation "ffmpeg"
        Write-Debug "ffmpeg_full_path: $ffmpeg_full_path"
        if( $ffmpeg_full_path.Length -eq 0 ) {
            throw "ffmpeg wasn't found. Exiting."
            return
        }
        Write-Verbose "Using ffmpeg at $ffmpeg_full_path"
    
        # if we haven't been supplied an ffProbe location, try at the same location as the ffMpegLocation
        if( $ffProbeLocation -eq "") {$ffProbeLocation = $ffMpegLocation}
        $ffprobe_full_path = GetBinaryLocation $ffProbeLocation "ffprobe"
        if( $ffprobe_full_path.Length -eq 0 ) {
            throw "ffprobe wasn't found. Exiting."
        }
        Write-Verbose "Using ffprobe at $ffprobe_full_path"
    
        if( ($RequiredImprovement -lt 0) -or ($RequiredImprovement -gt 99) )
        {
            Write-Warning "RequiredImprovement must be between 0 and 99. Defaulting to 10%."
            $RequiredImprovement = 10
        }
        Write-Verbose "Required improvement set to $RequiredImprovement%"
    
        # Get a timestamp for this invocation (that's just to create unique file names)
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        Write-Debug "Using time stamp $timestamp"
    }
    process {
        Write-Debug "process {}"

        # clear our array in case input is coming through the pipeline
        $files = @()

        # expand patterns, if any
        Write-Debug "Expanding file patterns:"
        foreach ($full_file_name_original in $inputFiles) {
            
            # expand or just get the single file (force array-type to ensure lists of individual files can be combined)
            $new_files = @(Get-ChildItem $full_file_name_original -ErrorAction SilentlyContinue)

            if( $new_files.Length -eq 0 ) {
                Write-Warning "$full_file_name_original does not map to any valid files"
            } else {
                if( $DebugPreference -ne "SilentlyContinue" ) {
                        Write-Debug "$full_file_name_original maps to:"
                        foreach( $f in $new_files ) {Write-Debug "$f"}
                }
            }
            # handle wild card patterns
            $files += $new_files
        }
        Write-Debug "Finished expanding file patterns."

        # remove duplicate entries that may come from expanding wildcard patterns while also receiving specific file at the same time
        $files = $files | Select-Object -Unique

        # the code below handles no files gracefully, but it's not the most user-friendly to say nothing, so make sure to inform the user 
        if( $files.Length -eq 0 ) {
            Write-Warning "No files to process. Exiting."
            return
        }

        # iterate over each files
        foreach ($full_file_name_original in $files) {    
            
            # Construct new file name, using the timestamp and new extension (which also implies the format)
            $short_file_name_original = (Split-Path -Path $full_file_name_original -Leaf)
            $short_file_name_new = (Split-Path -Path $full_file_name_original -LeafBase) + "_" + $timestamp + "." + $Extension
            $full_file_name_new = (Join-Path -Path (Split-Path -Path $full_file_name_original.FullName -Parent) -ChildPath $short_file_name_new)
            $original_file_date = $full_file_name_original.LastWriteTime

            # prepare an output line (some of the information we will fill in as we go along)
            $file_outcome = GetFileLine ($FullPathOutput ? $full_file_name_original : $short_file_name_original) ([ConversionOutcome]::Unknown) 0 ($FullPathOutput ? $full_file_name_new : $short_file_name_new)

            # reset progress
            if( !$Quiet) {Write-Progress -Activity ($short_file_name_original + " ==> " + $short_file_name_new) -PercentComplete 1 -Status "Getting ready..."}
            
            # create the log files in the temporary directories
            $log_file_output = $env:TEMP + "\output_" + $timestamp + ".log"
            $log_file_error = $env:TEMP + "\error_" + $timestamp + ".log"
            $log_file_progress = $env:TEMP + "\progress_" + $timestamp + ".log"
            $pass1_temporary_file = $env:TEMP + "\pass1_" + $timestamp + "." + $Extension
            $pass1_log_file_prefix = $env:TEMP + "\ffmpeg2pass-" + $timestamp # be mindful that this isn't a full file name, as ffmpeg will add extensions and final file name for the log file

            #use ffprobe to grab the length of the video (so we can do progress animations nicely)  
            $ffprobe_args = "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", """$full_file_name_original"""
            DebugPrintArgs $ffprobe_args
            $ffprobe_process = Start-Process -FilePath """$ffprobe_full_path""" $ffprobe_args -NoNewWindow -PassThru -RedirectStandardOutput $log_file_output -RedirectStandardError $log_file_error -Wait
            
            # move to next file if we couldn't read this one (we might have been supplied a file that wasn't a video)
            if( ProcessFailure $ffprobe_process $log_file_error ) {
                $file_outcome.Outcome = [ConversionOutcome]::Unreadable
                continue
            }

            # make sure we have the output file
            if (Test-Path $log_file_output -PathType Leaf) {
                # Read the captured output from the file
                $duration_seconds = Get-Content -Path $log_file_output
                Write-Debug "ffprobe returned video length of $duration_seconds"
            } else {
                Write-Warning "Couldn't determine input file lenght. Progress indicators will not be correct."
                $duration_seconds = 1.0        
            }    

            Write-Debug "Deleting previous progress file at $log_file_progress."
            # kill previous progress file so it doesn't pollute progress values on the next pass (a new progress file isn't written for a little while
            Remove-Item $log_file_progress -ErrorAction SilentlyContinue
            
            # we work in two passes - the first helps build information for a better encode in pass 2
            # pass 1
            Write-Debug "Pass 1 starting."
            $ffmpeg_args = "-i", """$full_file_name_original""", "-loglevel", "warning", "-vcodec", $VideoEncoder, "-b:v", ($VideoQuality.ToString() + "k"), "-pass", "1", "-an", "-f", "null", "-y", "-progress", $log_file_progress, "-passlogfile", $pass1_log_file_prefix, """$pass1_temporary_file"""
            DebugPrintArgs $ffmpeg_args
            [System.Diagnostics.Process]$ffmpeg_process = Start-Process -FilePath """$ffmpeg_full_path""" $ffmpeg_args -NoNewWindow -PassThru -RedirectStandardOutput $log_file_output -RedirectStandardError $log_file_error

            # wait for pass 1 to finish
            WriteProgress "Pre-encode" $ffmpeg_process $short_file_name_original $short_file_name_new $log_file_progress $duration_seconds 

            # move to next file if we couldn't read this one (we might have been supplied a file that wasn't a video)
            if( ProcessFailure $ffmpeg_process $log_file_error ) {
                $file_outcome.Outcome = [ConversionOutcome]::Error
                continue
            }

            # kill previous progress file so it doesn't pollute progress values on the next pass (a new progress file isn't written for a little while
            Remove-Item $log_file_progress -ErrorAction SilentlyContinue
            
            #pass 2
            Write-Debug "Pass 2 starting."
            $ffmpeg_args = "-i", """$full_file_name_original""", "-loglevel", "warning", "-vcodec", $VideoEncoder, "-b:v", ($VideoQuality.ToString() + "k"), "-pass", "2", "-c:a", $AudioEncoder, "-b:a", ($AudioQuality.ToString() + "k"), "-progress", $log_file_progress, "-passlogfile", $pass1_log_file_prefix, """$full_file_name_new"""
            DebugPrintArgs $ffmpeg_args
            $ffmpeg_process = Start-Process -FilePath """$ffmpeg_full_path""" $ffmpeg_args -NoNewWindow -PassThru -RedirectStandardOutput $log_file_output -RedirectStandardError $log_file_error

            # wait for pass 2 to finish
            WriteProgress "Encode" $ffmpeg_process $short_file_name_original $short_file_name_new $log_file_progress $duration_seconds

            # move to next file if we couldn't read this one (we might have been supplied a file that wasn't a video)
            if( ProcessFailure $ffmpeg_process $log_file_error ) {
                $file_outcome.Outcome = [ConversionOutcome]::Error
                Write-Output $file_outcome
                continue
            }

            # inspect the new file to compare against old file
            $old_file = Get-Item $full_file_name_original
            $new_file = Get-Item $full_file_name_new

            # now we know the new file size, we can compute the improvement percent
            $file_outcome.ImprovementPercent = ((($old_file.Length - $new_file.Length) / $old_file.Length) * 100.0)

            # set the new file's date to match the original file (unless requested not to)
            if( !$DontMatchDates ) {$new_file.LastWriteTime = $original_file_date}

            # if new file hasn't compressed enough, deal with that. Otherwise print confirmation.
            if( $new_file.Length -gt ($old_file.Length * (1 - ($RequiredImprovement / 100)))) {
                # delete the new file - it didn't compress hard enough
                Remove-Item $full_file_name_new

                # if we just kill the new file, tell the user we're discaring
                $file_outcome.Outcome = [ConversionOutcome]::Discarded
            } else {
                $file_outcome.Outcome = [ConversionOutcome]::Converted
            }      

            # file complete
            Write-Output $file_outcome
        }
    }
    end {
        Write-Debug "end {}"
        Write-Debug "<--"
    }
}
