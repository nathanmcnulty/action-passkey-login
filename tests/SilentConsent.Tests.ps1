BeforeAll {
 $scriptText=Get-Content "$PSScriptRoot/../PasskeyLogin.ps1" -Raw
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseInput($scriptText,[ref]$tokens,[ref]$errors)
}
Describe 'Unattended login boundaries' {
 It 'parses without errors' {$errors.Count|Should -Be 0}
 It 'stops an application-confirmation interrupt before submitting an HTTP request' {
  $loop=$ast.Find({param($node)$node -is [Management.Automation.Language.WhileStatementAst] -and $node.Condition.Extent.Text -match 'CmsiInterrupt'},$true)
  $loop|Should -Not -BeNullOrEmpty
  $Debug=@{pgid='CmsiInterrupt'};$InterruptHandlers=@{}
  Mock Invoke-WebRequest {throw 'Unexpected network call'}
  {& ([scriptblock]::Create($loop.Extent.Text))}|Should -Throw '*will not submit approval*'
  Should -Invoke Invoke-WebRequest -Times 0
 }
 It 'has no automatic consent submission or shortened credential output' {
  $scriptText|Should -Not -Match 'ContinueAuth\s*=|login.microsoftonline.com/appverify|credentialId.Substring|userHandle.Substring|Write-Verbose.*(?:fidoPayload|respVerify.Content|respFinalize.Content|Exception.Message)'
 }
}
