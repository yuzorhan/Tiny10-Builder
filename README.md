Tiny10 Builder

A lightweight Windows image builder inspired by Tiny11 Builder, designed for creating debloated and optimized Windows 10 installation ISOs from official Microsoft images.

Supports:

Windows 10 Home / Pro / Enterprise
LTSC
IoT LTSC
WIM and ESD source images

Tiny10 Builder performs offline servicing using DISM, removes unnecessary apps and telemetry components, applies system optimizations, rebuilds installation images, and exports a compact ISO automatically.

Features
Uses official Windows 10 ISOs only
Supports LTSC and IoT LTSC
Automatic WIM/ESD detection
Offline registry optimization
Appx package removal
Optional Microsoft Edge removal
Optional OneDrive removal
Telemetry reduction
Scheduled task cleanup
TPM/Secure Boot/RAM requirement bypass
boot.wim modification support
Automatic ISO rebuilding
Open source
Requirements
Windows 10 or Windows 11
Administrator privileges
PowerShell
Official Windows 10 ISO mounted or extracted
Enough free disk space for image extraction

Optional:

Windows ADK Deployment Tools (recommended)

If ADK is not installed, Tiny10 Builder automatically downloads oscdimg.exe.

Supported Editions
Windows 10 Home
Windows 10 Pro
Windows 10 Enterprise
Windows 10 LTSC
Windows 10 IoT LTSC

Notes
Only official Microsoft Windows ISOs are supported
Experimental builds may be unstable
Removing Edge WebView components may break some applications
Some Windows features may not work after aggressive debloating

Credits

Inspired by:

NTDEV Tiny11 Builder
Microsoft DISM Tools
Various deployment engineering tutorials and documentation

Warning

This project modifies Windows installation images.

Use at your own risk.

Always test generated ISOs inside a virtual machine before installing on real hardware.