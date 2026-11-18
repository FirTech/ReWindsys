If WScript.Arguments.Count <> 1 Then WScript.Quit 1
If Not IsNumeric(WScript.Arguments(0)) Then WScript.Quit 1
seconds = CDbl(WScript.Arguments(0))
If seconds < 0 Then WScript.Quit 1
WScript.Sleep seconds * 1000
