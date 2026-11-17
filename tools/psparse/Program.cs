using System.Management.Automation.Language;
int bad = 0;
foreach (var f in args) {
    Parser.ParseFile(f, out _, out var errs);
    foreach (var e in errs) { bad++; Console.WriteLine($"{Path.GetFileName(f)}:{e.Extent.StartLineNumber}: {e.Message}"); }
    if (errs.Length == 0) Console.WriteLine("ok " + Path.GetFileName(f));
}
return bad;
