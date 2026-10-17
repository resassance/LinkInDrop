param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LinkInDropThumbnail {
    [StructLayout(LayoutKind.Sequential)] public struct Size { public int Width; public int Height; }
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface Factory { void GetImage(Size size, int flags, out IntPtr bitmap); }
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
    public static extern void SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out Factory factory);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr value);
}
'@
$factory = $null
$bitmap = [IntPtr]::Zero
$image = $null
try {
    $iid = [Guid]'bcc18b79-ba16-442f-80c4-8a59c30c463b'
    [LinkInDropThumbnail]::SHCreateItemFromParsingName($Path, [IntPtr]::Zero, [ref]$iid, [ref]$factory)
    $size = New-Object LinkInDropThumbnail+Size
    $size.Width = 640
    $size.Height = 480
    $factory.GetImage($size, 8, [ref]$bitmap)
    $image = [System.Drawing.Image]::FromHbitmap($bitmap)
    $image.Save($Output, [System.Drawing.Imaging.ImageFormat]::Jpeg)
} finally {
    if ($image) { $image.Dispose() }
    if ($bitmap -ne [IntPtr]::Zero) { [void][LinkInDropThumbnail]::DeleteObject($bitmap) }
    if ($factory) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($factory) }
}
