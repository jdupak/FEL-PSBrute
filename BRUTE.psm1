using module .\EvaluationFormatting.psm1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"


$TOKEN_FILE_PATH = if (Get-Command Get-PSDataPath -ErrorAction Ignore) {
    # this function is from my custom profile (https://github.com/MatejKafka/powershell-profile)
    Get-PSDataPath -NoCreate BruteSSOToken.txt
} else {
    # user does not have my custom profile with Get-PSDataPath, use a fallback path
    Join-Path $PSScriptRoot "_BruteSSOToken.txt"
}


class InvalidBruteSSOTokenException : System.Exception {
    InvalidBruteSSOTokenException([string]$Message) : base($Message) {}
}

# copy the SSO authentication cookie from your browser; it times out after something like 1 hour of inactivity
# the cookie is always named "_shibsession_???...", the suffix varies
# I use the following browser bookmark to copy the SSO token to clipboard:
# `javascript:navigator.clipboard.writeText(document.cookie.split("; ").filter(c => c.startsWith("_shibsession")).join("; ")).then(() => alert("SSO token copied to the clipboard."), (err) => alert("Could not copy the SSO token: " + err))`
function Set-BruteSSOToken([Parameter(Mandatory)][string]$Token) {
    $Token = $Token.Trim()
    if ($Token -notmatch "^_shibsession_[a-zA-Z0-9]+=.+$") {
        throw "Invalid SSO token cookie format. Expected something like '_shibsession_...=...'."
    }
    Set-Content -NoNewline -Path $script:TOKEN_FILE_PATH $Token
}

function New-TemporaryPath($Extension = "", $Prefix = "") {
    $Tmp = if ($IsWindows) {$env:TEMP} else {"/tmp"}
    return Join-Path $Tmp "$Prefix$(New-Guid)$Extension"
}


function Get-HttpSession {
    if (-not (Test-Path $TOKEN_FILE_PATH)) {
        throw [InvalidBruteSSOTokenException]::new("SSO token not set, use 'Set-BruteSSOToken' to store it.")
    }
    $AuthCookieName, $AuthCookieValue = (Get-Content -Raw $TOKEN_FILE_PATH) -split "=", 2
    if (-not $AuthCookieValue) {
        throw [InvalidBruteSSOTokenException]::new("Malformed SSO token, use 'Set-BruteSSOToken' to replace it.")
    }
    $Session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $Session.Cookies.Add(([System.Net.Cookie]::new($AuthCookieName, $AuthCookieValue, "/", "cw.felk.cvut.cz")))
    return $Session
}

function Invoke-BruteRequest([Parameter(Mandatory)][uri]$Url, [Hashtable]$PostParameters = $null, $OutFile) {
    $IwrParams = if ($PostParameters) {
        # copy parameter Hashtable over to the query string dictionary $qp; for some reason,
        #  the query string .NET class is not public, so we parse an empty string to get a usable instance
        $qp = [System.Web.HttpUtility]::ParseQueryString("")
        foreach ($k in $PostParameters.Keys) {
            $qp[$k] = $PostParameters[$k]
        }
        @{Method = "POST"; Body = $qp.ToString(); ContentType = "application/x-www-form-urlencoded"}
    } else {
        @{} # GET request, no extra params
    }
    if ($OutFile) {$IwrParams["OutFile"] = $OutFile}

    try {
        return Invoke-WebRequest $Url -WebSession (Get-HttpSession) -MaximumRedirection 0 @IwrParams
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        $res = $_.Exception.Response
        # check if we are being redirected to the SSO portal
        if ($res.StatusCode -eq 302 -and $res.Headers.Location.OriginalString.StartsWith("https://idp2.civ.cvut.cz")) {
            throw [InvalidBruteSSOTokenException]::new("Not authorized, did the SSO token expire?")
        }
        throw
    }
}

function Get-BruteUpload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][BruteEvaluation]$Evaluation,
        [Parameter(Mandatory)][string]$OutputDir
    )

    $DownloadUrl = $Evaluation.SubmissionUrl
    # BRUTE always returns .tgz archives
    $DownloadPath = New-TemporaryPath ".tgz"
    try {
        Invoke-BruteRequest $DownloadUrl -OutFile $DownloadPath
        $null = New-Item -Type Directory $OutputDir -Force
        tar xzf $DownloadPath --directory $OutputDir
    } finally {
        Remove-Item -ErrorAction Ignore $DownloadPath
    }
}

class BruteEvaluation {
    [string]$UserName
    [string]$Url
    [string]$SubmissionUrl
    [string]$AeOutputUrl
    [bool]$EvaluationFieldIsRaw
    [pscustomobject]$Parameters

    [bool] SetScore([Nullable[float]]$ManualScore, [Nullable[float]]$Penalty = $null) {
        $Acceptable = $true # indicates if the submission is acceptable
        $Recompute = $false # indicates if total score should be recomputed
        $p = $this.Parameters

        if ($null -ne $Penalty) {
            $Recompute = $true
            $p.penalty = $Penalty
        }
        if ($null -ne $ManualScore) {
            $Recompute = $true
            $p.manual_score = $ManualScore
        } else {
            $Acceptable = $false
            $p.manual_score = $null
            $p.score = $null
        }

        if ($Recompute) {
            $penalty = if ($p.penalty -eq "") {0} else {[float]::Parse($p.penalty)}
            $manual = if ($p.manual_score -eq "") {0} else {[float]::Parse($p.manual_score)}
            # round to hide float rounding errors
            $p.score = [math]::Round($ManualScore + $penalty + [float]::Parse($p.ae_score), 4)
            if ($p.score -lt 0) {
                $Acceptable = $false
            }
        }

        $p.status = if ($Acceptable) {"0"} else {"1"}
        return $Acceptable
    }

    [void] SetEvaluationText([string]$EvaluationText) {
        $this.Parameters.evaluation = $EvaluationText
        $this.EvaluationFieldIsRaw = $EvaluationText -eq ""
    }

    [void] SetNote([string]$Note) {
        if ($Note.IndexOf("</textarea>") -ge 0) {
            throw "Note must not contain the substring '</textarea>', otherwise it would break the evaluation page."
        }
        $this.Parameters.note = $Note
    }
}

function Get-BruteEvaluation {
    # .SYNOPSIS
    # Scrapes the passed evaluation page from BRUTE to retrieve the current evaluation (if set)
    # and hidden parameters necessary to submit a new evaluation (assignment ID, student ID,...).
    [CmdletBinding()]
    [OutputType([BruteEvaluation])]
    param([Parameter(Mandatory)][uri]$Url)

    # list of input fields to scrape from the evaluation page
    $ForwardedInputFields = @(
        "manual_score", "ae_score", "penalty", "score", "assignment_id", "course_id",
        "id", "team_id", "status", "hours_after_deadline", "student_id", "submit_evaluation")

    if ($Url -notmatch "(https://cw.felk.cvut.cz/brute/teacher/upload/\d+)/\d+") {
        throw "Invalid evaluation URL: '$Url'"
    }
    $SubmissionDownloadUrl = $Matches[1] + "/download"

    $Response = Invoke-BruteRequest $Url
    
    $AEParams = @{}
    # this is a file upload input to upload a custom PDF evaluation, not implemented yet
    $AEParams.upload_result = $null
    # "Text Evaluation" text field
    $EvalRaw, $AEParams.evaluation = Get-OriginalEvaluationText $Response.Content "EVALUATION"
    # "Note" text field
    $AEParams.note = Get-TextareaContent $Response.Content "note"

    $AeOutputUrl = $null
    $UserName = $null
    foreach ($l in $Response.Links) {
        if ($l.href -like "/brute/data/*") {
            $AeOutputUrl = "https://cw.felk.cvut.cz" + $l.href
        } elseif ($l.href -match "/brute/teacher/student/(.*)") {
            $UserName = $Matches[1]
        }
    }
    if (-not $AeOutputUrl) {throw "Could not find AE output link in the HTML."}
    if (-not $UserName) {throw "Could not find student username in the HTML."}

    foreach ($FieldName in $ForwardedInputFields) {
        $Field = $Response.InputFields.FindByName($FieldName)
        if (-not $Field) {throw "Forwarded input field with 'name=`"$FieldName`"' not found in the AE page."}
        try {$AEParams[$Field.Name] = $Field.value}
        catch {throw "Forwarded field with 'name=`"$FieldName`"' in the AE page has no value."}
    }

    return [BruteEvaluation]@{
        UserName = $UserName
        Url = $Url
        SubmissionUrl = $SubmissionDownloadUrl
        AeOutputUrl = $AeOutputUrl
        EvaluationFieldIsRaw = $EvalRaw
        Parameters = $AEParams
    }
}

function Set-BruteEvaluation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][BruteEvaluation]$Evaluation)

    $p = $Evaluation.Parameters
    # render 'Evaluation Text' if not raw
    $p.evaluation = if ($Evaluation.EvaluationFieldIsRaw) {$p.evaluation} else {Format-EvaluationText $p.evaluation "EVALUATION"}

    try {
        $null = Invoke-BruteRequest "https://cw.felk.cvut.cz/brute/teacher/upload.php" -PostParameters $p
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        # 302 is the standard response for this endpoint
        if ($_.Exception.Response.StatusCode -ne 302) {
            throw
        } elseif ($_.Exception.Response.Headers.Location.OriginalString -notlike "/brute/teacher/course/*") {
            throw "Unexpected submission redirect target, check if it was submitted correctly: '$($_.Exception.Response.Headers.Location.OriginalString)'"
        }
    }    
}

function New-BruteEvaluation {
    # .SYNOPSIS
    # Convenience wrapper around Get-BruteEvaluation and Set-BruteEvaluation.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Url,
        [Nullable[float]]$ManualScore = $null,
        [Nullable[float]]$Penalty = $null,
        $Evaluation = $null,
        $Note = $null
    )

    $eval = Get-BruteEvaluation $Url
    
    $null = $eval.SetScore($ManualScore, $Penalty)
    
    if ($null -ne $Evaluation) {
        $eval.SetEvaluationText($Evaluation)
    }
    if ($null -ne $Note) {
        $eval.SetNote($Note)
    }

    return Set-BruteEvaluation $eval
}


class BruteSubmissionInfo {
    [string]$UserName
    [string]$Url
    [bool]$Submitted
    [Nullable[float]]$AeScore = $null
    [float]$Penalty = 0
    [Nullable[float]]$ManualScore = $null

    [string] Format() {
        if (-not $this.Submitted) {return "---"}
        $s = ""
        $s += if ($null -ne $this.ManualScore) {"" + $this.ManualScore}
        if ($null -ne $this.AeScore) {
            $s += if ($null -ne $this.ManualScore) {"+"} else {"("}
            $s += $global:PSStyle.Foreground.BrightBlue + $this.AeScore + $global:PSStyle.Reset
            $s += if ($null -eq $this.ManualScore) {")"}
        }
        if ($this.Penalty) {$s += $global:PSStyle.Foreground.BrightRed + "-" + $this.Penalty + $global:PSStyle.Reset}
        return $s
    }
}

class BruteStudent {
    [string]$UserName

    hidden [BruteParallel]$_Parallel
    hidden [int]$_FirstSubmissionLinkI

    [string] GetSubmissionURL([string]$AssignmentName) {
        return $this.GetSubmissionURL($this._Parallel.GetAssignmentI($AssignmentName))
    }

    [BruteSubmissionInfo] GetSubmissionInfo([string]$AssignmentName) {
        return $this.GetSubmissionScore($this._Parallel.GetAssignmentI($AssignmentName))
    }

    [string] GetSubmissionURL([int]$AssignmentI) {
        # e.g. https://cw.felk.cvut.cz/brute/teacher/upload/1370876/12898
        $Link = $this._Parallel._Response.Links[$this._FirstSubmissionLinkI + $AssignmentI]
        if ($Link.href -like "/brute/teacher/upload/new/*/*" -or $Link.outerHTML -like "*>---<*") {
            return $null # nothing uploaded yet
        }
        return "https://cw.felk.cvut.cz" + $Link.href
    }

    [BruteSubmissionInfo] GetSubmissionInfo([int]$AssignmentI) {
        $Link = $this._Parallel._Response.Links[$this._FirstSubmissionLinkI + $AssignmentI]
        $Html = $Link.outerHTML
        $Info = [BruteSubmissionInfo]@{UserName = $this.UserName; Url = $this.GetSubmissionURL($AssignmentI)}
        if ($Html -like '<a href="*">---*</a>') {
            # not uploaded yet
            $Info.Submitted = $false
            return $Info
        }

        $Info.Submitted = $true
        if ($Html -match '<SPAN CLASS="red"> - (-?\d+(\.\d+)?)</SPAN>') {
            $Info.Penalty = $Matches[1]
        }
        if ($Html -match '<SPAN CLASS="blue">(-?\d+(\.\d+)?)</SPAN>') {
            $Info.AeScore = $Matches[1]
        }
        if ($Html -match '<span style="font-weight: bold">(-?\d+(\.\d+)?)') {
            $Info.ManualScore = $Matches[1]
        }
        return $Info
    }

    [pscustomobject] Format() {
        $Out = [ordered]@{UserName = $this.UserName}
        $Names = $this._Parallel.GetAssignmentNames()
        for ($i = 0; $i -lt @($Names).Count; $i++) {
            $Out[$Names[$i]] = $this.GetSubmissionInfo($i).Format()
        }
        return [pscustomobject]$Out
    }
}

class BruteParallel {
    [string]$TabID
    [string]$ID
    [string]$Name

    hidden [Microsoft.PowerShell.Commands.BasicHtmlWebResponseObject]$_Response
    hidden [string[]]$_AssignmentNames = $null
    hidden [int]$_AssignmentNameLastI = -1
    hidden [BruteStudent[]]$_Students = $null

    [string[]] GetAssignmentNames() {
        if ($this._AssignmentNames) {
            return $this._AssignmentNames
        }
        $Names = @()
        $LastMatchI = -1
        $i = -1
        foreach ($l in $this._Response.Links) {
            $i++
            if ($l.PSObject.Properties.Name -notcontains "data-parallel") {
                continue
            }
            if ($l."data-parallel" -eq $this.TabID) {
                $Names += $l."data-title"
                $LastMatchI = $i
            } elseif ($Names) {
                break # finished
            }
        }
        $this._AssignmentNames = $Names
        $this._AssignmentNameLastI = $LastMatchI
        return $Names
    }

    [int] GetAssignmentI($AssignmentName) {
        $Names = $this.GetAssignmentNames()
        for ($i = 0; $i -lt $Names.Count; $i++) {
            # use -like to allow wildcard lookup
            if ($Names[$i] -like $AssignmentName) {
                return $i
            }
        }
        throw "Assignment '$AssignmentName' not found for parallel '$($this.Name)'."
    }

    [BruteStudent[]] GetStudents() {
        if ($this._Students) {
            return $this._Students
        }
        if (-not $this._AssignmentNames) {
            # load up the `_AssignmentNameLastI`
            $null = $this.GetAssignmentNames()
        }

        $Students = @()
        for ($i = $this._AssignmentNameLastI + 1; $i -lt $this._Response.Links.Count; $i++) {
            $l = $this._Response.Links[$i]
            if ($l.PSObject.Properties.Name -contains "data-target" -and $l."data-target" -eq "#quickEvaluationModal") {
                break # we reached the next tab header
            } elseif ($l.href -match "^/brute/teacher/student/([a-z0-9]+)$") {
                $Students += [BruteStudent]@{
                    _Parallel = $this
                    _FirstSubmissionLinkI = $i - $this._AssignmentNames.Count
                    UserName = $Matches[1]
                }
            }
        }
        $this._Students = $Students
        return $Students
    }

    [BruteStudent] GetStudent($UserName) {
        $Student = $this.GetStudents() | ? {$_.UserName -eq $UserName}
        if (-not $Student) {
            throw "Student '$UserName' not found for parallel '$($this.Name)'."
        }
        return $Student
    }

    [string[]] GetSubmissionURLs([string]$AssignmentName) {
        $ai = $this.GetAssignmentI($AssignmentName)
        return $this.GetStudents().GetSubmissionURL($ai)
    }

    [pscustomobject[]] FormatTable() {
        return $this.GetStudents().Format() | Format-Table -Property * -AutoSize
    }
}

class BruteCourseTable {
    [string]$CourseUrl
    hidden [Microsoft.PowerShell.Commands.BasicHtmlWebResponseObject]$_Response
    hidden [BruteParallel[]]$_Parallels = $null

    BruteCourseTable($CourseUrl) {
        $this.CourseUrl = $CourseUrl
        $this._Response = Invoke-BruteRequest $CourseUrl
    }

    [BruteParallel] GetParallel([string]$ID) {
        if ($this._Parallels) {
            return $this._Parallels | ? ID -eq $ID
        }
        foreach ($l in $this._Response.Links) {
            if ($l.PSObject.Properties.Name -contains "data-toggle" -and $l."data-toggle" -eq "tab" -and $l.href -match "#\d+") {
                $null = $l.outerHTML -match ">([^<]+)</[aA]>"
                if ($ID -eq $Matches[1]) {
                    return [BruteParallel]@{
                        _Response = $this._Response
                        TabID = $l."data-id"
                        ID = $Matches[1]
                        Name = $l.title
                    }
                }
            }
        }
        throw "Parallel '$ID' not found for course '$($this.CourseUrl)'."
        return $null # not found
    }

    [BruteParallel[]] GetParallels() {
        if ($this._Parallels) {
            return $this._Parallels
        }
        $Parallels = @()
        foreach ($l in $this._Response.Links) {
            if ($l.PSObject.Properties.Name -contains "data-toggle" -and $l."data-toggle" -eq "tab" -and $l.href -match "#\d+") {
                $null = $l.outerHTML -match ">([^<]+)</[aA]>"
                $Parallels += [BruteParallel]@{
                    _Response = $this._Response
                    TabID = $l."data-id"
                    ID = $Matches[1]
                    Name = $l.title
                }
            } elseif ($Parallels) {
                break # finished, all parallels are listed continously, and we found a non-parallel link
            }
        }
        $this._Parallels = $Parallels
        return $Parallels
    }
}

function Get-BruteCourseTable {
    # .SYNOPSIS
    # Retrieve course information.
    [CmdletBinding()]
    [OutputType([BruteCourseTable])]
    param([Parameter(Mandatory)][uri]$CourseUrl)

    return [BruteCourseTable]::new($CourseUrl)
}
