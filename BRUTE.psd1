@{
	RootModule = 'BRUTE.psm1'
	ModuleVersion = '0.1'
	GUID = '69f72f74-7719-4daf-a440-73a0d2cafa01'
	Author = 'Matej Kafka'

	Description = 'Functions to interface with the BRUTE evaluation system at FEE CTU in Prague.'

	FunctionsToExport = @('Set-BruteSSOToken', 'New-BruteEvaluation', 'Get-BruteEvaluation', 'Set-BruteEvaluation', 'Get-BruteUpload', 'Get-BruteCourseTable')
	CmdletsToExport = @()
	VariablesToExport = @()
	AliasesToExport = @()
}

