# Disposable Windows 10 client startup test

This infrastructure boots the actual Microsoft Windows 10 Enterprise Evaluation 22H2 x64 ISO under QEMU/KVM on a disposable Linux runner. It does not use a Windows Server guest. It does not install third-party guest display, network, or storage drivers.

## Required host

- Linux x64 with accessible `/dev/kvm` (check before committing to the test).
- `qemu-system-x86_64`, `qemu-img`, `genisoimage`, `python3`, `curl`, `sha256sum`.
- 4 GiB available guest RAM and approximately 25–35 GiB free disk during installation. The 40 GiB guest disk is sparse.
- No host port forwarded to the guest or published to the internet. The evidence/package HTTP service binds only to host loopback, reached from the guest as `10.0.2.2:8765` through QEMU user-mode networking.
- GitHub nested virtualization is experimental and not officially supported: https://docs.github.com/en/actions/concepts/runners/github-hosted-runners

Run:

```sh
bash run-windows10-vm.sh /path/to/ScreenTrail-0.1.15-Setup.exe /path/to/Test-Windows10Startup.ps1 /path/to/artifacts
```

`WINDOWS10_ISO_PATH` may point to a previously downloaded ISO. Its SHA256 is always checked. Microsoft currently serves the 5,550,497,792-byte ISO successfully; the official verification PDF confirms SHA256 `ef7312733a9f5d7d51cfa04ac497671995674ca5e1058d5164d6028f0938d668`.

`CANDIDATE_APPHOST_PATH` may point to an optional diagnostic application host. When set, it is served at `/candidate.exe`. The guest script must independently check its pinned hash and record it separately from baseline launch evidence; bootstrap never installs or launches the candidate itself.

The unattended setup wipes only its brand-new virtual Disk 0, installs the evaluation edition with no product key, creates a random disposable Administrator password, and signs in automatically. The password and virtual disk are deleted at the end. Windows Update's service is disabled in this disposable guest to preserve the exact verified 19045.2006 ISO baseline. Windows firewall, Defender, UAC, and crash reporting remain at their image defaults. No RDP service is enabled. The built-in Administrator account differs from a normal user account and should be recorded as a test limitation. Host CPU flags and QEMU's guest CPU model are recorded, including any CET support actually exposed by the hypervisor.

## Guest script contract

Provide `Test-Windows10Startup.ps1` accepting:

```powershell
param([string]$InstallerPath, [string]$ResultsDirectory)
```

It runs as an interactive desktop process after Explorer is present. It must:

- Install the supplied exact published installer. Its size and SHA256 were already verified independently on host and guest.
- Verify VC prerequisite installation on this clean Windows client (do not preinstall VC on the image).
- Launch the installed real executable, observe actual visible windows/tray/process exit, and capture errors and a screenshot.
- Save `result.json` plus other evidence inside `$ResultsDirectory`, and exit nonzero on failure.

Bootstrap downloads both files from host loopback, caps the guest script at 15 minutes, uploads evidence files (one file per POST, up to 40 MiB each), and posts a completion status. The host caps VM execution at 30 minutes and captures a QMP screenshot every two minutes plus on completion/timeout. Evidence survives even when the test fails; virtual disk and seed do not.

This infrastructure has been parsed/linted locally but cannot be boot-tested on the current macOS ARM64 host. A passing runner test must include the guest's `ProductType=1`, build `19045`, and actual window evidence; successful KVM startup alone is insufficient.
