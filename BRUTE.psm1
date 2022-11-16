using module .\EvaluationFormatting.psm1
using module .\Utils.psm1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"


$TOKEN_FILE_PATH = if (Get-Command Get-PSDataPath -ErrorAction Ignore) {
    Get-PSDataPath -NoCreate BruteSSOToken.txt
} else {
    # user does not have my custom profile with Get-PSDataPath, use a fallback path
    Join-Path $PSScriptRoot "_BruteSSOToken.txt"
}

# copy the SSO authentication cookie from your browser; it times out after something like 1 hour of inactivity
# the cookie is always named "_shibsession_???...", the suffix varies
function Set-BruteSSOToken([Parameter(Mandatory)][string]$Token) {
    $Token = $Token.Trim()
    if ($Token -notmatch "^_shibsession_[a-zA-Z0-9]+=.+$") {
        throw "Invalid SSO token cookie format. Expected something like '_shibsession_...=...'."
    }
    Set-Content -NoNewline -Path $script:TOKEN_FILE_PATH $Token
}


function Get-HttpSession {
    if (-not (Test-Path $TOKEN_FILE_PATH)) {
        throw "SSO token not set, use 'Set-BruteSSOToken' to store it."
    }
    $AuthCookieName, $AuthCookieValue = (cat -Raw $TOKEN_FILE_PATH) -split "=", 2
    if (-not $AuthCookieValue) {
        throw "Malformed SSO token, use 'Set-BruteSSOToken' to replace it."
    }
    $Session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $Session.Cookies.Add(([System.Net.Cookie]::new($AuthCookieName, $AuthCookieValue, "/", "cw.felk.cvut.cz")))
    return $Session
}

function Invoke-BruteRequest([Parameter(Mandatory)][uri]$Url, [Hashtable]$PostParameters = $null, $OutFile) {
    $IwrParams = if ($PostParameters) {
        # copy parameter Hashtable over to the query string dictionary $qp
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
            throw "Not authorized, did the SSO token expire?"
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
    $DownloadPath = New-TmpPath ".tgz"
    try {
        Invoke-BruteRequest $DownloadUrl -OutFile $DownloadPath
        $null = mkdir $OutputDir -Force
        tar xzf $DownloadPath --directory $OutputDir
    } finally {
        rm -ErrorAction Ignore $DownloadPath
    }
}

class BruteEvaluation {
    [string]$Url
    [string]$SubmissionUrl
    [string]$AeOutputUrl
    [bool]$EvaluationFieldIsRaw
    [bool]$NoteFieldIsRaw
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
        $this.EvaluationFieldIsRaw = $false
    }

    [void] SetNote([string]$Note) {
        $this.Parameters.note = $Note
        $this.NoteFieldIsRaw = $false
    }
}

function Get-BruteEvaluation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uri]$Url)

    $ForwardedInputFields = @(
        "manual_score", "ae_score", "penalty", "score", "assignment_id", "course_id",
        "id", "team_id", "status", "hours_after_deadline", "student_id", "submit_evaluation")

    if ($Url -notmatch "(https://cw.felk.cvut.cz/brute/teacher/upload/\d+)/\d+") {
        throw "Invalid evaluation URL: '$Url'"
    }
    $SubmissionDownloadUrl = $Matches[1] + "/download"

    $Response = Invoke-BruteRequest $Url
    
    $AEParams = @{}
    $AEParams.upload_result = $null
    # "Text Evaluation" text field
    $EvalRaw, $AEParams.evaluation = Get-OriginalEvaluationText $Response.Content "EVALUATION"
    # "Note" text field
    $NoteRaw, $AEParams.note = Get-OriginalEvaluationText $Response.Content "NOTE"

    $AeOutputUrl = $Response.Links | ? href -like "/brute/data/*" | select -First 1 | % {"https://cw.felk.cvut.cz" + $_.href}

    foreach ($FieldName in $ForwardedInputFields) {
        $Field = $Response.InputFields.FindByName($FieldName)
        if (-not $Field) {throw "Forwarded input field with 'name=`"$FieldName`"' not found in the AE page."}
        try {$AEParams[$Field.Name] = $Field.value}
        catch {throw "Forwarded field with 'name=`"$FieldName`"' in the AE page has no value."}
    }
    return [BruteEvaluation]@{
        Url = $Url
        SubmissionUrl = $SubmissionDownloadUrl
        AeOutputUrl = $AeOutputUrl
        EvaluationFieldIsRaw = $EvalRaw
        NoteFieldIsRaw = $NoteRaw
        Parameters = $AEParams
    }
}

function Set-BruteEvaluation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][BruteEvaluation]$Evaluation)

    $p = $Evaluation.Parameters
    # render 'Evaluation Text' and 'Note' if not raw
    $p.evaluation = if ($Evaluation.EvaluationFieldIsRaw) {$p.evaluation} else {Format-EvaluationText $p.evaluation "EVALUATION"}
    $p.note = if ($Evaluation.NoteFieldIsRaw) {$p.note} else {Format-EvaluationText $p.note "NOTE"}

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


class BruteStudent {
    [string]$UserName

    hidden [BruteParallel]$_Parallel
    hidden [int]$_FirstSubmissionLinkI

    [string] GetSubmissionURL([string]$AssignmentName) {
        return $this.GetSubmissionURL($this._Parallel.GetAssignmentI($AssignmentName))
    }

    [string] GetSubmissionURL([int]$AssignmentI) {
        # e.g. https://cw.felk.cvut.cz/brute/teacher/upload/1370876/12898
        return "https://cw.felk.cvut.cz" + $this._Parallel._Response.Links[$this._FirstSubmissionLinkI + $AssignmentI].href
    }

    # TODO: add method to extract the assignment info (points, acceptability) from the <a> content
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

function Get-BruteCourseTable([Parameter(Mandatory)][uri]$CourseUrl) {
    return [BruteCourseTable]::new($CourseUrl)
}
