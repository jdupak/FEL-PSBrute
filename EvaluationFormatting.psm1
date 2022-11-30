Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:PREFIX = @'
<style>
    pre {display: none;}
    #evaluation-xss-div ul {padding-inline-start: 16px;}
    #evaluation-xss-div {
        background-color: #f5f5f5;
        border-radius: 4px;
        font-size: 85%;
        padding: 6px;
        border: 1px solid #ccc;
    }
</style>
<div id="evaluation-xss-div">
'@

$script:SUFFIX = @'
</div>
'@

function _GetContentMarkers($Tag) {
    return "<<<${Tag} TAG START b041f162-99c6-4d75-a039-50f3c94e97be>>>", "<<<${Tag} TAG END b041f162-99c6-4d75-a039-50f3c94e97be>>>"

}

function Format-EvaluationText([Parameter(Mandatory)]$Str, [Parameter(Mandatory)]$Tag) {
    $MarkerStart, $MarkerEnd = _GetContentMarkers $Tag
    $OriginalContentComment = "<!--" + $MarkerStart + "`n" + $Str + "`n" + $MarkerEnd + "-->"

    # use pandoc to render Markdown to HTML
    $RenderedStr = echo $Str | pandoc --from gfm --to html
    return "</pre>`n`n" + $OriginalContentComment + "`n`n" + $script:PREFIX + "`n$RenderedStr`n" + $script:SUFFIX + "`n<pre>"
}

function Get-TextareaContent($EvalPageContent, $TextareaName) {
    # ?s: = make `.` match all characters, including a newline
    # .*? = lazy match, find the first </textarea> occurrence, not the last
    $Pattern = '<textarea class="[^"]+" cols="\d*" rows="\d*" id="[^"]+" name="' + $TextareaName + '"\s*>(?s:(.*?))</textarea>'
    if ($EvalPageContent -match $Pattern) {
        return $Matches[1]
    }
    return $null
}

function Get-OriginalEvaluationText([Parameter(Mandatory)]$EvalPageContent, [Parameter(Mandatory)]$Tag) {
    $MarkerStart, $MarkerEnd = _GetContentMarkers $Tag.ToUpper()
    $i = $EvalPageContent.IndexOf($MarkerStart)
    $iEnd = $EvalPageContent.IndexOf($MarkerEnd)
    if ($i -lt 0 -or $iEnd -lt 0) {
        # did not find the marks, try to just find the <textarea> and get the raw content
        return $true, (Get-TextareaContent $EvalPageContent $Tag.ToLower())
    }
    # +1 / -1 to account for the added newline
    $iStart = $i + $MarkerStart.Length + 1
    return $false, $EvalPageContent.Substring($iStart, $iEnd - $iStart - 1)
}

Export-ModuleMember Format-EvaluationText, Get-OriginalEvaluationText, Get-TextareaContent