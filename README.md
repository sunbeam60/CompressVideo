# CompressVideo
A pwsh wrapper around ffmpeg, used mainly for personal video archival batching. Might be useful for others.

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
